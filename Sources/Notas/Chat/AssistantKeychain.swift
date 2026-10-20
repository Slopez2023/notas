import Foundation
import Security

/// Generic-password storage for the user's OpenCode API key. The key lives only here and in the
/// Codex child's environment; it is never written to the note library, chat history, or logs.
/// Credential reads and writes for the assistant. Production uses the Keychain; tests pass memory.
struct AssistantCredentialAccess {
    var read: () -> String?
    var save: (String) throws -> Void
    var delete: () -> Void

    static let keychain = AssistantCredentialAccess(
        read: { AssistantKeychain.read() },
        save: { try AssistantKeychain.save($0) },
        delete: { AssistantKeychain.delete() }
    )
}

enum AssistantKeychain {
    static var service = "com.stephenlopez.notas.assistant"
    private static let account = "opencode-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AssistantError.message("The key couldn't be saved to the Keychain (\(status)).") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw AssistantError.message("The key couldn't be saved to the Keychain (\(added)).") }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
