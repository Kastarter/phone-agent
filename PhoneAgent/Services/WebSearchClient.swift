import Foundation

private final class SearchRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct WebSearchClient {
    let settings: WebSearchSettings
    let apiKey: String
    // Injection is for isolated verification; production always uses bounded ephemeral transport.
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = Self.load
    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: SearchRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.message("The search service did not return an HTTP response") }
            guard (200...299).contains(http.statusCode) else { throw httpError(http.statusCode) }
            guard http.expectedContentLength <= 1_000_000 else { throw AgentError.message("Search response exceeds 1 MB; not saved") }
            var data = Data()
            for try await byte in bytes {
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                guard data.count < 1_000_000 else { throw AgentError.message("Search response exceeds 1 MB; not saved") }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AgentError.message(error.code == .timedOut ? "Search request timed out. Try again later" : "Can't connect to the search service. Check your network")
        }
    }
    static func httpError(_ code: Int) -> AgentError {
        if code == 401 || code == 403 { return .message("Search service HTTP \(code). Check the search key and permissions") }
        if [429,432,433].contains(code) { return .message("Search service HTTP \(code). Check your quota or try again later") }
        return .message("Search service HTTP \(code). No results were saved")
    }
    func request(query: String) throws -> URLRequest {
        let query = try WebSearchBatch.validatedQuery(query)
        guard !apiKey.isEmpty, apiKey.utf8.count <= 4096, apiKey.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else { throw AgentError.message("Save a valid search service API key first") }
        var url = settings.provider.endpoint
        if settings.provider == .brave {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "q", value: query), .init(name: "count", value: "5"), .init(name: "text_decorations", value: "false"), .init(name: "safesearch", value: "moderate")]
            if let freshness = settings.freshness.brave { c.queryItems?.append(.init(name: "freshness", value: freshness)) }
            url = c.url!
        }
        var req = URLRequest(url: url); req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if settings.provider == .tavily {
            req.httpMethod = "POST"; req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["query": query, "search_depth": "basic", "max_results": 5, "topic": "general", "include_published_date": true,
                                     "include_answer": false, "include_raw_content": false, "include_images": false, "auto_parameters": false]
            if settings.freshness != .any { body["time_range"] = settings.freshness.rawValue }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else { req.httpMethod = "GET"; req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token") }
        return req
    }
    func search(query: String) async throws -> WebSearchBatch {
        let query = try WebSearchBatch.validatedQuery(query)
        let req = try request(query: query); try Task.checkCancellation()
        let (data, http) = try await transport(req); try Task.checkCancellation()
        guard http.url == req.url else { throw AgentError.message("Search response came from a mismatched service and was discarded") }
        guard (200...299).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
        return try Self.decode(data, query: query, settings: settings, date: Date())
    }
    static func decode(_ data: Data, query: String, settings: WebSearchSettings, date: Date) throws -> WebSearchBatch {
        guard data.count <= 1_000_000 else { throw AgentError.message("Search response exceeds 1 MB; not saved") }
        struct Entry: Decodable { let title: String; let url: String; let content: String?; let description: String?; let published_date: String?; let page_age: String?; let age: String? }
        struct Web: Decodable { let results: [Entry] }
        struct Query: Decodable { let original: String? }
        struct Envelope: Decodable { let results: [Entry]?; let web: Web?; let query: Query? }
        let e: Envelope
        // Tavily uses a string query; Brave uses an object. Decode only the selected protocol.
        do {
            if settings.provider == .tavily {
                struct Tavily: Decodable { let results: [Entry] }
                e = Envelope(results: try JSONDecoder().decode(Tavily.self, from: data).results, web: nil, query: nil)
            } else { e = try JSONDecoder().decode(Envelope.self, from: data) }
        } catch { throw AgentError.message("The search service did not return a complete, valid result format") }
        let entries: [Entry]
        if settings.provider == .tavily, let list = e.results { entries = list }
        else if settings.provider == .brave, e.web != nil || e.query?.original != nil { entries = e.web?.results ?? [] }
        else { throw AgentError.message("The search service response has no result list") }
        guard entries.count <= 20 else { throw AgentError.message("The search service returned an unexpected number of results") }
        var sources: [WebSearchSource] = []; var seen = Set<String>()
        for entry in entries {
            let raw = (settings.provider == .tavily ? entry.content : entry.description)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sources.count < 5, let url = WebSearchBatch.sourceURL(entry.url), !raw.isEmpty, !title.isEmpty,
                  seen.insert(url.absoluteString).inserted else { continue }
            // Plain text only: no HTML rendering, external images or scripts.
            let cleaned = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let label = (settings.provider == .tavily ? entry.published_date : entry.page_age ?? entry.age)?.trimmingCharacters(in: .whitespacesAndNewlines)
            sources.append(.init(id: sources.count + 1, title: String(title.prefix(200)), url: url, excerpt: String(cleaned.prefix(1400)),
                                 publishedLabel: label.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }, excerptShortened: cleaned.count > 1400))
        }
        return .init(query: query, provider: settings.provider, freshness: settings.freshness, retrievedAt: date, sources: sources, omitted: entries.count - sources.count)
    }
}

// Executes only the finite reviewed plan; never asks a model to extend it.
struct WebResearchClient {
    let settings: WebSearchSettings
    let apiKey: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = WebSearchClient.load
    func search(question: String, plan: WebSearchPlan, progress: @MainActor (WebSearchBatch) -> Void) async throws -> WebSearchBatch {
        try plan.validate()
        guard try WebSearchBatch.validatedQuery(question) == question else { throw AgentError.message("The question changed. Review the plan again") }
        // Validate every request before spending any search quota.
        let clients = try plan.queries.map { item -> WebSearchClient in
            let client = WebSearchClient(settings: .init(provider: settings.provider, freshness: item.freshness), apiKey: apiKey, transport: transport)
            _ = try client.request(query: item.query); return client
        }
        try Task.checkCancellation()
        var results: [WebSearchBatch] = []
        for (index, client) in clients.enumerated() {
            try Task.checkCancellation()
            results.append(try await client.search(query: plan.queries[index].query))
            try Task.checkCancellation()
            await progress(try WebSearchBatch.merged(question: question, plan: plan, batches: results))
            try Task.checkCancellation()
        }
        return try WebSearchBatch.merged(question: question, plan: plan, batches: results)
    }
}
