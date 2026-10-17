import Foundation
import Security

enum RealtimeStore {
    static func load(defaults: UserDefaults = .standard) -> RealtimeSettings { defaults.data(forKey: "agent.realtime.settings").flatMap { try? JSONDecoder().decode(RealtimeSettings.self, from: $0) } ?? .init() }
    static func save(_ settings: RealtimeSettings, key: String, defaults: UserDefaults = .standard) throws {
        _ = try settings.validate()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhoneAgent.realtime", kSecAttrAccount as String: settings.endpoint]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Failed to clear the realtime key") }
        } else {
            _ = try settings.request(key: key)
            let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
            guard status == errSecSuccess else { throw AgentError.message("Failed to save the realtime key") }
        }
        defaults.set(try JSONEncoder().encode(settings), forKey: "agent.realtime.settings")
    }
    static func key(for settings: RealtimeSettings) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhoneAgent.realtime", kSecAttrAccount as String: settings.endpoint, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
