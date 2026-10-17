import Foundation

// Consent follows the actual recipient. Changing endpoints requires consent again.
enum PrivacyConsent {
    static let revision = 7
    private static let key = "agent.aiConsent.v1"
    struct Grant: Codable { let endpoint: String; let provider: String; let revision: Int }
    static func recipient(_ settings: AgentSettings) -> String {
        if let name = settings.providerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let host = URLComponents(string: settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? "No provider configured"
        if host == "api.openai.com" { return "OpenAI" }
        if host == "openrouter.ai" { return "OpenRouter" }
        if host.hasPrefix("bedrock-runtime.") && host.hasSuffix(".amazonaws.com") {
            return "AWS Bedrock (" + host.dropFirst("bedrock-runtime.".count).dropLast(".amazonaws.com".count) + ")"
        }
        return host
    }
    static func allowed(_ settings: AgentSettings, defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: key), let grant = try? JSONDecoder().decode(Grant.self, from: data) else { return false }
        return grant.endpoint == endpoint(settings) &&
            grant.provider == recipient(settings) && grant.revision == revision
    }
    static func grant(_ settings: AgentSettings, defaults: UserDefaults = .standard) {
        let value = Grant(endpoint: endpoint(settings), provider: recipient(settings), revision: revision)
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
    private static func endpoint(_ settings: AgentSettings) -> String {
        settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func revoke(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
