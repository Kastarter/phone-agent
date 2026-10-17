import Foundation

struct WebPageExcerpt: Codable, Equatable {
    let url: URL
    let text: String
    let start: Int
    let totalCharacters: Int
    let retrievedAt: Date
    func validate() throws {
        guard (1...120000).contains(totalCharacters), start >= 0, start <= totalCharacters,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 12000,
              start + text.count <= totalCharacters, retrievedAt.timeIntervalSince1970.isFinite,
              WebPageDocument.canonicalURL(url) != nil else { throw AgentError.message("The page excerpt or source info is invalid and was not used for the answer") }
    }
    var label: String { "Tavily text chars \(start + 1)–\(start + text.count) of \(totalCharacters) extracted · Retrieved \(ISO8601DateFormatter().string(from: retrievedAt)) (not the page publish time)" }
}
struct WebPageDocument {
    let url: URL
    let text: String
    let retrievedAt: Date
    func excerpt(start: Int, length: Int) throws -> WebPageExcerpt {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 120000,
              start >= 0, start < text.count, (1...12000).contains(length), length <= text.count - start else { throw AgentError.message("Select a continuous 1–12000 character range within the extracted text") }
        let value = WebPageExcerpt(url: url, text: String(text.dropFirst(start).prefix(length)), start: start, totalCharacters: text.count, retrievedAt: retrievedAt)
        try value.validate(); return value
    }
    static func canonicalURL(_ url: URL) -> String? {
        guard WebSearchBatch.sourceURL(url.absoluteString) != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        parts.fragment = nil; parts.host = parts.host?.lowercased(); parts.scheme = parts.scheme?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.url?.absoluteString
    }
}
extension WebSearchBatch {
    func validatePageEvidence() throws {
        for source in sources {
            if let excerpt = source.pageExcerpt {
                try excerpt.validate()
                guard WebPageDocument.canonicalURL(excerpt.url) == WebPageDocument.canonicalURL(source.url) else { throw AgentError.message("The text source does not match the search link") }
            }
        }
    }
    func usingPage(sourceID: Int, excerpt: WebPageExcerpt?) throws -> Self {
        try validateResearchEvidence(); try validatePageEvidence()
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { throw AgentError.message("The search sources changed; select again") }
        if let excerpt {
            try excerpt.validate()
            guard WebPageDocument.canonicalURL(excerpt.url) == WebPageDocument.canonicalURL(sources[index].url) else { throw AgentError.message("The text source does not match the confirmed link") }
        }
        var changed = sources; changed[index].pageExcerpt = excerpt
        let value = Self(query: query, provider: provider, freshness: freshness, retrievedAt: retrievedAt, sources: changed, omitted: omitted, plan: plan, completedQueries: completedQueries, researchTrail: researchTrail, researchStop: researchStop)
        guard value.referenceText.count <= 40000 else { throw AgentError.message("The model material exceeds 40000 characters. Shorten the selected text; existing material was not truncated or replaced") }
        return value
    }
}
