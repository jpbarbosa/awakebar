import Foundation
import Security

// MARK: - OAuth token storage (AwakeBar's own Keychain item)
//
// Persists the live-usage OAuth token in a generic-password item AwakeBar owns
// (service `UsageAPI.oauthKeychainService`, NOT `Claude Code-credentials`).
// Because the item is created and read by the same signed app, macOS never shows
// an access prompt — which is the whole point: it sidesteps the cross-app
// prompt/ACL churn that sank the old "read Claude Code's token" approach.
//
// Not unit-tested (it's Keychain IO); the value it stores is the pure,
// tested `UsageOAuth.Token`.
enum TokenStore {
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: UsageAPI.oauthKeychainService]
    }

    static func load() -> UsageOAuth.Token? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(UsageOAuth.Token.self, from: data)
    }

    // Replace any existing item. We own the ACL, so the delete+add (which would
    // reset a cross-app grant) is harmless here.
    @discardableResult
    static func save(_ token: UsageOAuth.Token) -> Bool {
        guard let data = try? JSONEncoder().encode(token) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
