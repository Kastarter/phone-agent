import Foundation

// The app calls the fixed extraction service, never the page URL itself.
struct WebPageClient {
    static let endpoint = URL(string: "https://api.tavily.com/extract")!
    let apiKey: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = WebSearchClient.load
    func request(url: URL) throws -> URLRequest {
        guard let value = WebPageDocument.canonicalURL(url) else { throw AgentError.message("Select a valid HTTP / HTTPS source link") }
        guard !apiKey.isEmpty, apiKey.utf8.count <= 4096, apiKey.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else { throw AgentError.message("Save a valid Tavily key first; the Brave or model key is not used") }
        var request = URLRequest(url: Self.endpoint); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No query/chunks option: request the page text rather than reranked snippets.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["urls": [value], "extract_depth": "basic", "format": "text", "include_images": false, "include_favicon": false, "timeout": 20, "include_usage": false])
        return request
    }
    func read(url: URL) async throws -> WebPageDocument {
        try Task.checkCancellation(); let request = try request(url: url)
        let (data, response) = try await transport(request); try Task.checkCancellation()
        guard response.url == Self.endpoint else { throw AgentError.message("The page-text service response came from a mismatched endpoint and was discarded") }
        guard (200...299).contains(response.statusCode) else { throw WebSearchClient.httpError(response.statusCode) }
        return try Self.decode(data, requestedURL: url, date: Date())
    }
    static func decode(_ data: Data, requestedURL: URL, date: Date) throws -> WebPageDocument {
        guard data.count <= 1_000_000, date.timeIntervalSince1970.isFinite, let requested = WebPageDocument.canonicalURL(requestedURL) else { throw AgentError.message("The page-text response or link is out of range and was not saved") }
        struct Entry: Decodable { let url: String; let raw_content: String }
        struct Failure: Decodable { let url: String; let error: String? }
        struct Envelope: Decodable { let results: [Entry]; let failed_results: [Failure] }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data), value.results.count + value.failed_results.count == 1 else { throw AgentError.message("The page-text service did not return a complete single-link result; existing material was not replaced") }
        if let failure = value.failed_results.first {
            guard let url = WebSearchBatch.sourceURL(failure.url), WebPageDocument.canonicalURL(url) == requested else { throw AgentError.message("The page-text service returned an unconfirmed source and was discarded") }
            // Do not expose provider error bodies, URLs or credentials in errors.
            throw AgentError.message("The service could not extract this page's text; open the source directly to verify. No login or access restriction was bypassed.")
        }
        guard let entry = value.results.first, let url = WebSearchBatch.sourceURL(entry.url), WebPageDocument.canonicalURL(url) == requested else { throw AgentError.message("The returned page text does not match the confirmed web page and was discarded") }
        guard !entry.raw_content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.raw_content.count <= 120000 else { throw AgentError.message("The page text is empty or exceeds 120,000 characters; it was not truncated or saved") }
        return .init(url: requestedURL, text: entry.raw_content, retrievedAt: date)
    }
}
