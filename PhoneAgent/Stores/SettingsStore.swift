import Foundation
import Security

enum SettingsStore {
    static func load() -> AgentSettings {
        var value = stored()
        // Builds with a bundled OpenRouter key move once to GPT-6 Luna on OpenRouter (the most accurate measured model); later choices stick.
        if bundledOpenRouterKey != nil, !UserDefaults.standard.bool(forKey: "agent.openRouterBootstrap.v1") {
            UserDefaults.standard.set(true, forKey: "agent.openRouterBootstrap.v1")
            let defaults = AgentSettings()
            value.endpoint = defaults.endpoint; value.model = defaults.model; value.providerName = nil
            value.jsonMode = true; value.legacyTokenLimit = false
            save(value)
        }
        return value
    }
    private static func stored() -> AgentSettings {
        guard let data = UserDefaults.standard.data(forKey: "agent.settings"),
              var value = try? JSONDecoder().decode(AgentSettings.self, from: data) else { return AgentSettings() }
        // Builds that ship Bedrock credentials move an existing install to Bedrock once; later choices stick.
        if bundledBedrockCredentials != nil, !UserDefaults.standard.bool(forKey: "agent.bedrockBootstrap.v1") {
            UserDefaults.standard.set(true, forKey: "agent.bedrockBootstrap.v1")
            let defaults = AgentSettings()
            value.endpoint = defaults.endpoint; value.model = defaults.model; value.providerName = nil
            value.jsonMode = defaults.jsonMode; value.legacyTokenLimit = defaults.legacyTokenLimit
            save(value)
        }
        return value
    }
    /// AWS credentials bundled at build time from the git-ignored Resources/BedrockCredentials.json.
    static let bundledBedrockCredentials: String? = {
        guard let url = Bundle.main.url(forResource: "BedrockCredentials", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }()
    /// An OpenRouter key bundled at build time from the git-ignored Resources/OpenRouterKey.txt.
    static let bundledOpenRouterKey: String? = {
        guard let url = Bundle.main.url(forResource: "OpenRouterKey", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }()
    static func save(_ settings: AgentSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "agent.settings") }
    }
    static func calibration() -> PointerCalibration? {
        guard let data = UserDefaults.standard.data(forKey: "agent.calibration") else { return nil }
        return try? JSONDecoder().decode(PointerCalibration.self, from: data)
    }
    static func saveCalibration(_ value: PointerCalibration?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "agent.calibration")
    }
    static func credentialMatches(_ endpoint: String) -> Bool {
        UserDefaults.standard.string(forKey: "agent.keyEndpoint") == endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func adoptLegacyCredential(for endpoint: String) {
        if UserDefaults.standard.string(forKey: "agent.keyEndpoint") == nil {
            UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent.keyEndpoint")
        }
    }
    static func apiKey(for endpoint: String? = nil) -> String {
        let endpoint = endpoint ?? load().endpoint
        let stored = keychainKey(for: endpoint)
        if stored.isEmpty, AgentSettings.isBedrock(endpoint), let bundled = bundledBedrockCredentials { return bundled }
        if stored.isEmpty, URLComponents(string: endpoint)?.host == "openrouter.ai", let bundled = bundledOpenRouterKey { return bundled }
        return stored
    }
    private static func keychainKey(for endpoint: String) -> String {
        guard credentialMatches(endpoint) else { return "" }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func saveAPIKey(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: "api-key"]
        if key.isEmpty { SecItemDelete(query as CFDictionary); UserDefaults.standard.removeObject(forKey: "agent.keyEndpoint"); return }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw AgentError.message("Failed to save API key: \(result)") }
        UserDefaults.standard.set(load().endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent.keyEndpoint")
    }
}
