import Foundation
import Security

enum WebSearchStore {
    static func load(defaults: UserDefaults = .standard) -> WebSearchSettings {
        defaults.data(forKey: "agent.webSearch.settings").flatMap { try? JSONDecoder().decode(WebSearchSettings.self, from: $0) } ?? .init()
    }
    static func save(_ value: WebSearchSettings, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(value), forKey: "agent.webSearch.settings")
    }
    static func key(_ provider: WebSearchProvider) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhoneAgent.search",
                                  kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func saveKey(_ key: String, for provider: WebSearchProvider) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhoneAgent.search", kSecAttrAccount as String: provider.rawValue]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Couldn't clear the search key") }; return
        }
        guard key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else { throw AgentError.message("Invalid search key format") }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AgentError.message("Couldn't save the search key") }
    }
}
