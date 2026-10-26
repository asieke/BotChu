import Foundation
import Security

/// Generic passwords under the service `local.BotChu`.
enum Keychain {
    static let service = "local.BotChu"
    @MainActor static var remoteQueueAccount: String { DevHooks.dataDir == nil ? "remote-queue" : "remote-queue-dev" }
    static let openRouterAccount = "openrouter"
    /// The Telegram gateway's bot token. A review copy (`DevHooks`) has its own, so it never reads
    /// the real bot's messages.
    @MainActor static var telegramAccount: String { DevHooks.dataDir == nil ? "telegram" : "telegram-dev" }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or deletes the item when it is empty.
    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Replaces a credential without first deleting its working value. Remote token rotation
    /// reports failure and keeps the old token if Keychain refuses an update.
    static func setChecked(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil) == errSecSuccess
    }
}
