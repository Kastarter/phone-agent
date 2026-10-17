// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class BrainRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let original: URL
    init(original: URL) { self.original = original }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { ModelEndpointPolicy.permitsRedirect(from: original, to: $0) } == true ? request : nil)
    }
}

/// Client for the configured OpenAI-compatible Chat Completions endpoint, streamed (SSE) with a plain-JSON
/// fallback. The endpoint is already the full …/chat/completions URL.
@MainActor final class BrainLLM: ChatModel {
    static let tokenParams = ["max_tokens", "max_completion_tokens"]
    let model: String
    private let endpoint: String
    private let apiKey: String
    private var tokenParam: String
    private var switched = false
    private var session: URLSession?

    init(settings: AgentSettings, apiKey: String) {
        endpoint = settings.endpoint
        model = settings.model
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenParam = settings.legacyTokenLimit ? "max_tokens" : "max_completion_tokens"
    }

    static func isTimeout(_ error: Error) -> Bool { (error as? URLError)?.code == .timedOut }

    /// An empty reply is asked once more; one cut by the token limit is asked again at double the limit.
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        let first = try await once(system: system, text: text, image: image, maxTokens: maxTokens, temperature: temperature)
        guard first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return first }
        let limit = first.finishReason == "length" ? maxTokens * 2 : maxTokens
        var again = try await once(system: system, text: text, image: image, maxTokens: limit, temperature: temperature)
        again.total += first.total
        return again
    }

    private func client(_ url: URL) -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30  // no byte for this long = hung; the agent retries
        config.timeoutIntervalForResource = 90
        let made = URLSession(configuration: config, delegate: BrainRedirectGuard(original: url), delegateQueue: nil)
        session = made
        return made
    }

    private func once(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        var content: [[String: Any]] = image.map {
            [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]]
        } ?? []
        content.append(["type": "text", "text": text])
        let body: [String: Any] = ["model": model, "temperature": temperature, "stream": true,
            "messages": [["role": "system", "content": system], ["role": "user", "content": content]]]
        let started = brainNow()
        var (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
        if status == 400, !switched, let other = Self.tokenParams.first(where: { $0 != tokenParam }),
           errorText.contains(other) || errorText.contains(tokenParam) {
            (tokenParam, switched) = (other, true)
            (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
        }
        guard (200..<300).contains(status), var result else {
            throw LLMError(message: "Model HTTP \(status): \(errorText.prefix(300))")
        }
        result.total = brainNow() - started
        return result
    }

    private func post(_ body: [String: Any], maxTokens: Int, started: Double) async throws -> (Int, ChatResult?, String) {
        let url = try ModelEndpointPolicy.url(endpoint)
        var body = body
        body[tokenParam] = maxTokens
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await client(url).bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(status), type.contains("text/event-stream") else {
            var raw = Data()
            for try await b in bytes { raw.append(b) }
            guard (200..<300).contains(status) else { return (status, nil, String(decoding: raw, as: UTF8.self)) }
            return (status, try Self.message(raw), "")  // a plain JSON answer
        }
        var result = ChatResult(text: "", firstToken: nil, total: 0)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            try Self.checkError(json)
            let choice = (json["choices"] as? [[String: Any]])?.first
            let delta = choice?["delta"] as? [String: Any]
            if let reason = choice?["finish_reason"] as? String { result.finishReason = reason }
            result.reasoningChars += Self.reasoning(delta).count
            guard let piece = delta?["content"] as? String, !piece.isEmpty else { continue }
            if result.firstToken == nil { result.firstToken = brainNow() - started }
            result.text += piece
        }
        return (status, result, "")
    }

    /// choices[0].message of a non-streamed reply.
    static func message(_ raw: Data) throws -> ChatResult {
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        if let json { try checkError(json) }
        let choice = (json?["choices"] as? [[String: Any]])?.first
        guard let msg = choice?["message"] as? [String: Any] else {
            throw LLMError(message: "The model reply has no message")
        }
        var result = ChatResult(text: msg["content"] as? String ?? "", firstToken: nil, total: 0)
        result.finishReason = choice?["finish_reason"] as? String
        result.reasoningChars = reasoning(msg).count
        return result
    }

    /// Providers can report errors inside an HTTP 200 stream or JSON response.
    private static func checkError(_ json: [String: Any]) throws {
        guard let error = json["error"] else { return }
        let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "Provider error"
        throw LLMError(message: String(message.prefix(300)))
    }

    /// Reasoning text (vLLM/DeepSeek `reasoning_content`, others `reasoning`).
    private static func reasoning(_ part: [String: Any]?) -> String {
        part?["reasoning_content"] as? String ?? part?["reasoning"] as? String ?? ""
    }
}
