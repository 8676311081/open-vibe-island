import Foundation
import Security

/// Errors surfaced from credential storage. Read-side
/// "missing-key" is NOT an error here — `credential(for:)` returns
/// `nil` so callers can branch on "key present" without try/catch.
public enum RouterCredentialsError: LocalizedError, Sendable {
    case keychainSystemError(status: OSStatus)
    case credentialEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .keychainSystemError(let status):
            return "Keychain operation failed (OSStatus \(status))."
        case .credentialEncodingFailed:
            return "Could not encode credential as UTF-8 data."
        }
    }
}

/// Storage interface used by `RouterCredentialsStore` so tests can
/// inject an in-memory backend without exercising the system Keychain
/// (avoids polluting the developer's login keychain with throwaway
/// `sk-test-...` items).
public protocol RouterCredentialsBackend: Sendable {
    func setCredential(_ value: String, for account: String) throws
    func credential(for account: String) throws -> String?
    func deleteCredential(for account: String) throws
    func listAccounts() throws -> [String]
}

/// Single read/write surface for routing credentials (e.g. the
/// DeepSeek API key consumed by the upcoming `Authorization`-header
/// rewrite path in `LLMProxyServer`). Conceptually a tiny
/// account→secret map, partitioned from the rest of the app's
/// `~/.claude/settings.json` / `UserDefaults` so a credential never
/// lands in cleartext on disk.
///
/// Production callers use `RouterCredentialsStore.live()` — backed by
/// `KeychainCredentialsBackend` and the macOS login keychain. Tests
/// inject an in-memory backend.
public final class RouterCredentialsStore: Sendable {
    /// Default Keychain service string. Tests override via the
    /// backend; production callers shouldn't need to change this.
    public static let defaultService = "app.openisland.dev.routing-credentials"

    private let backend: any RouterCredentialsBackend

    public init(backend: any RouterCredentialsBackend) {
        self.backend = backend
    }

    /// Production constructor — uses `KeychainCredentialsBackend`
    /// against the macOS login keychain.
    public static func live(service: String = defaultService) -> RouterCredentialsStore {
        RouterCredentialsStore(backend: KeychainCredentialsBackend(service: service))
    }

    public func setCredential(_ value: String, for account: String) throws {
        try backend.setCredential(value, for: account)
    }

    public func credential(for account: String) throws -> String? {
        try backend.credential(for: account)
    }

    public func deleteCredential(for account: String) throws {
        try backend.deleteCredential(for: account)
    }

    public func listAccounts() throws -> [String] {
        try backend.listAccounts()
    }

    /// Convenience for UI code that just wants to know whether a key
    /// exists (e.g. to disable a "DeepSeek" model card until the user
    /// configures the credential). Swallows backend errors and
    /// reports missing — UI code generally shouldn't surface a
    /// keychain failure as "key present" anyway.
    public func hasCredential(for account: String) -> Bool {
        (try? credential(for: account)) != nil
    }
}

// MARK: - Keychain backend (production)

/// Generic-password keychain access scoped to a single
/// `kSecAttrService`. Items are accessible after first device unlock
/// (`kSecAttrAccessibleAfterFirstUnlock`) — Open Island runs as a
/// background-launching menu-bar app, so the more restrictive
/// `WhenUnlocked*` modes would break credential reads when launchd
/// starts the app before the user attends the keychain.
public final class KeychainCredentialsBackend: RouterCredentialsBackend {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func setCredential(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw RouterCredentialsError.credentialEncodingFailed
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update path is the common case (overwrite an existing key).
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            // Fall through to add with the same query plus value + accessibility.
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            throw RouterCredentialsError.keychainSystemError(status: addStatus)
        }
        throw RouterCredentialsError.keychainSystemError(status: updateStatus)
    }

    public func credential(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            throw RouterCredentialsError.keychainSystemError(status: status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public func deleteCredential(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Treat already-absent as success — caller's intent is "make
        // sure this account has no credential", which is satisfied.
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw RouterCredentialsError.keychainSystemError(status: status)
    }

    public func listAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        if status != errSecSuccess {
            throw RouterCredentialsError.keychainSystemError(status: status)
        }
        guard let items = result as? [[String: Any]] else { return [] }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted()
    }
}
