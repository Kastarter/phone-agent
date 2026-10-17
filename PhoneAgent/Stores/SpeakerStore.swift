import Foundation
import Security

enum SpeakerStore {
    static func load(defaults: UserDefaults = .standard) -> SpeakerSettings { defaults.data(forKey: "agent.speaker.settings").flatMap { try? JSONDecoder().decode(SpeakerSettings.self, from: $0) } ?? .init() }
    static func save(_ settings: SpeakerSettings, key: String, defaults: UserDefaults = .standard) throws {
        _ = try settings.validate()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhoneAgent.speaker", kSecAttrAccount as String: settings.endpoint]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Couldn't clear the diarization key") }
        } else {
            guard SpeakerSettings.validKey(key) else { throw AgentError.message("Invalid diarization key format") }
            let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
            guard status == errSecSuccess else { throw AgentError.message("Couldn't save the diarization key") }
        }
        defaults.set(try JSONEncoder().encode(settings), forKey: "agent.speaker.settings")
    }
    static func key(for settings: SpeakerSettings) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhoneAgent.speaker", kSecAttrAccount as String: settings.endpoint, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
