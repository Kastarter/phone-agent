import Foundation
import CryptoKit

/// AWS Bedrock transport for VisionClient.
///
/// The app speaks OpenAI Chat Completions everywhere. When the configured endpoint is a
/// `bedrock-runtime.<region>.amazonaws.com` host, VisionClient hands the finished Chat
/// Completions request to this adapter, which rewrites it as a Bedrock Converse call,
/// signs it with SigV4, and turns the Converse reply back into a Chat Completions body.
///
/// Credentials are temporary STS credentials pasted into the API key field as the JSON
/// printed by `scripts/bedrock-credentials.sh` (`aws sts get-session-token` output shape).
/// No long-term AWS secret is ever stored on the phone.
enum BedrockClient {
    static let defaultRegion = "eu-central-1"
    static func endpoint(region: String = defaultRegion) -> String {
        "https://bedrock-runtime.\(region).amazonaws.com/chat/completions"
    }
    /// Vision-capable Bedrock models (cross-region inference profiles); your account must have them enabled.
    static let models: [(id: String, label: String)] = [
        ("global.openai.gpt-6-luna", "GPT-6 Luna"),
        ("global.openai.gpt-6-sol", "GPT-6 Sol"),
        ("global.anthropic.claude-sonnet-5", "Claude Sonnet 5"),
        ("global.anthropic.claude-opus-5-5", "Claude Opus 5.5"),
    ]

    static func region(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasPrefix("bedrock-runtime."), host.hasSuffix(".amazonaws.com") else { return nil }
        let middle = host.dropFirst("bedrock-runtime.".count).dropLast(".amazonaws.com".count)
        return middle.isEmpty || middle.contains(".") ? nil : String(middle)
    }
    static func isBedrock(_ endpoint: String) -> Bool {
        URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(region(for:)) != nil
    }

    struct Credentials: Decodable {
        var AccessKeyId: String
        var SecretAccessKey: String
        var SessionToken: String?
        var Expiration: String?

        static func parse(_ text: String) throws -> Credentials {
            var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Accept the full `aws sts get-session-token` output as well as the inner object.
            if let data = raw.data(using: .utf8),
               let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inner = outer["Credentials"],
               let innerData = try? JSONSerialization.data(withJSONObject: inner) {
                raw = String(decoding: innerData, as: UTF8.self)
            }
            guard let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(Credentials.self, from: data),
                  !value.AccessKeyId.isEmpty, !value.SecretAccessKey.isEmpty else {
                throw AgentError.message("Bedrock needs temporary AWS credentials. On the Mac run scripts/bedrock-credentials.sh, then paste the copied JSON into the key field.")
            }
            if let expiry = value.expiryDate, expiry <= Date() {
                throw AgentError.message("Bedrock credentials expired at \(expiry.formatted(date: .abbreviated, time: .shortened)). Run scripts/bedrock-credentials.sh on the Mac and paste the new JSON.")
            }
            return value
        }
        var expiryDate: Date? {
            guard let Expiration else { return nil }
            let full = ISO8601DateFormatter(); full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ISO8601DateFormatter().date(from: Expiration) ?? full.date(from: Expiration)
        }
    }

    // MARK: Request translation (Chat Completions -> Converse)

    /// Builds a signed Converse request from a Chat Completions request VisionClient already assembled.
    static func converseRequest(from chat: URLRequest, credentials: String) throws -> URLRequest {
        guard let url = chat.url, let region = region(for: url) else { throw AgentError.message("Not a Bedrock endpoint") }
        let credentials = try Credentials.parse(credentials)
        guard let body = chat.httpBody, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AgentError.message("Bedrock request body is missing")
        }
        guard let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            throw AgentError.message("Choose a Bedrock model ID")
        }
        var system: [[String: Any]] = []
        var messages: [[String: Any]] = []
        for message in object["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            let blocks = try contentBlocks(message["content"])
            guard !blocks.isEmpty else { continue }
            if role == "system" || role == "developer" {
                system += blocks.filter { $0["text"] != nil }
                continue
            }
            let converseRole = role == "assistant" ? "assistant" : "user"
            // Converse requires alternating roles; merge consecutive turns from the same side.
            if var last = messages.last, last["role"] as? String == converseRole {
                last["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": converseRole, "content": blocks])
            }
        }
        // Converse requires the conversation to start with a user turn.
        if messages.first?["role"] as? String == "assistant" {
            messages.insert(["role": "user", "content": [["text": "(conversation continues)"]]], at: 0)
        }
        guard !messages.isEmpty else { throw AgentError.message("Bedrock request has no user message") }
        var converse: [String: Any] = ["messages": messages]
        if !system.isEmpty { converse["system"] = system }
        if let limit = (object["max_completion_tokens"] ?? object["max_tokens"]) as? Int {
            converse["inferenceConfig"] = ["maxTokens": limit]
        }
        // response_format (JSON mode) has no Converse equivalent; the prompts already demand JSON only.

        let modelPath = model.addingPercentEncoding(withAllowedCharacters: unreserved) ?? model
        var target = URLComponents()
        target.scheme = "https"; target.host = "bedrock-runtime.\(region).amazonaws.com"
        target.percentEncodedPath = "/model/\(modelPath)/converse"
        var request = URLRequest(url: target.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = max(chat.timeoutInterval, 60)
        request.httpBody = try JSONSerialization.data(withJSONObject: converse)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        sign(&request, region: region, credentials: credentials)
        return request
    }

    /// A tiny signed Converse call used by "Test connection".
    static func pingRequest(endpoint: String, model: String, credentials: String) throws -> URLRequest {
        var chat = URLRequest(url: try ModelEndpointPolicy.url(endpoint))
        chat.httpMethod = "POST"; chat.timeoutInterval = 30
        chat.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_completion_tokens": 16,
            "messages": [["role": "user", "content": "Reply with OK."]],
        ] as [String: Any])
        return try converseRequest(from: chat, credentials: credentials)
    }

    private static func contentBlocks(_ content: Any?) throws -> [[String: Any]] {
        if let text = content as? String { return text.isEmpty ? [] : [["text": text]] }
        guard let parts = content as? [[String: Any]] else { return [] }
        return try parts.compactMap { part in
            switch part["type"] as? String {
            case "text":
                guard let text = part["text"] as? String, !text.isEmpty else { return nil }
                return ["text": text]
            case "image_url":
                guard let url = (part["image_url"] as? [String: Any])?["url"] as? String ?? part["image_url"] as? String else { return nil }
                return try imageBlock(dataURI: url)
            default:
                return nil
            }
        }
    }

    private static func imageBlock(dataURI: String) throws -> [String: Any] {
        guard dataURI.hasPrefix("data:image/"), let comma = dataURI.firstIndex(of: ",") else {
            throw AgentError.message("Bedrock only accepts inline images")
        }
        let header = dataURI[dataURI.index(dataURI.startIndex, offsetBy: 11)..<comma]
        var format = header.split(separator: ";").first.map(String.init)?.lowercased() ?? "jpeg"
        if format == "jpg" { format = "jpeg" }
        guard ["jpeg", "png", "gif", "webp"].contains(format) else { throw AgentError.message("Bedrock does not accept image/\(format)") }
        // Converse JSON carries image bytes as base64, which the data URI already holds.
        return ["image": ["format": format, "source": ["bytes": String(dataURI[dataURI.index(after: comma)...])]]]
    }

    // MARK: Response translation (Converse -> Chat Completions)

    /// Returns a Chat Completions shaped body and the status code VisionClient should see.
    static func chatCompletionsBody(fromConverse data: Data, status: Int) -> Data {
        guard (200...299).contains(status) else {
            // Keep only the error message; VisionClient maps the status code to user-facing text.
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? "Bedrock HTTP \(status)"
            return (try? JSONSerialization.data(withJSONObject: ["error": ["message": message]])) ?? Data()
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = (object["output"] as? [String: Any])?["message"] as? [String: Any]
        let text = (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        let finish: String
        switch object["stopReason"] as? String {
        case "max_tokens": finish = "length"
        case "content_filtered", "guardrail_intervened": finish = "content_filter"
        default: finish = "stop"
        }
        let usage = object["usage"] as? [String: Any]
        let chat: [String: Any] = [
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": finish]],
            "usage": ["prompt_tokens": usage?["inputTokens"] as? Int ?? 0, "completion_tokens": usage?["outputTokens"] as? Int ?? 0,
                      "total_tokens": usage?["totalTokens"] as? Int ?? 0],
        ]
        return (try? JSONSerialization.data(withJSONObject: chat)) ?? Data()
    }

    // MARK: SigV4

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func sign(_ request: inout URLRequest, region: String, credentials: Credentials, now: Date = Date()) {
        let service = "bedrock"
        let amzDate: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f.string(from: now)
        }()
        let day = String(amzDate.prefix(8))
        let host = request.url!.host!
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.SessionToken, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }

        let payloadHash = hex(SHA256.hash(data: request.httpBody ?? Data()))
        var headers: [(String, String)] = [("content-type", request.value(forHTTPHeaderField: "Content-Type") ?? ""), ("host", host), ("x-amz-date", amzDate)]
        if let token = credentials.SessionToken, !token.isEmpty { headers.append(("x-amz-security-token", token)) }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()
        // Non-S3 services encode each path segment twice in the canonical URI.
        let path = request.url!.path(percentEncoded: true)
        let canonicalURI = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }.joined(separator: "/")
        let canonicalRequest = [request.httpMethod ?? "POST", canonicalURI, "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }
        let signingKey = hmac(hmac(hmac(hmac(Data("AWS4\(credentials.SecretAccessKey)".utf8), day), region), service), "aws4_request")
        let signature = hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.AccessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}
