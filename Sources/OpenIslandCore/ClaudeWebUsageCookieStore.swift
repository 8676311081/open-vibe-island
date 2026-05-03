import Foundation
import Security

/// Stores the Claude Web session cookie that powers the realtime
/// usage poller in macOS Keychain.
///
/// Uses `kSecClassInternetPassword` (not `GenericPassword`) because the
/// stored value is a web session cookie scoped to a specific server —
/// per-DeepSeek's review, this matches Keychain semantics, gets a clean
/// "Open Island — Claude Web Session" entry in Keychain Access.app, and
/// avoids the access-prompt that some `GenericPassword` configurations
/// trigger.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly` so the poller can
/// run after the user logs in once per boot, but the secret never leaves
/// the device.
public protocol ClaudeWebUsageCookieStoring: Sendable {
    func loadCookie() throws -> String?
    func saveCookie(_ cookie: String) throws
    func deleteCookie() throws
}

public enum ClaudeWebUsageCookieStoreError: Error, Equatable {
    case keychainFailure(OSStatus)
    case invalidCookie

    public var localizedDescription: String {
        switch self {
        case let .keychainFailure(status):
            return "Keychain operation failed with status \(status)"
        case .invalidCookie:
            return "Cookie value is empty or not UTF-8"
        }
    }
}

public struct ClaudeWebUsageCookieStore: ClaudeWebUsageCookieStoring {
    public static let server = "claude.ai"
    public static let account = "session-token"
    public static let label = "Open Island — Claude Web Session"

    public init() {}

    public func loadCookie() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ClaudeWebUsageCookieStoreError.keychainFailure(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    public func saveCookie(_ cookie: String) throws {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw ClaudeWebUsageCookieStoreError.invalidCookie
        }

        let queryForUpdate = baseQuery()
        let attrsForUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.label,
        ]

        let updateStatus = SecItemUpdate(queryForUpdate as CFDictionary, attrsForUpdate as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = Self.label
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ClaudeWebUsageCookieStoreError.keychainFailure(addStatus)
            }
        default:
            throw ClaudeWebUsageCookieStoreError.keychainFailure(updateStatus)
        }
    }

    public func deleteCookie() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw ClaudeWebUsageCookieStoreError.keychainFailure(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: Self.server,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

/// In-memory store used by tests so we never touch the user's real Keychain.
public final class InMemoryClaudeWebUsageCookieStore: ClaudeWebUsageCookieStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cookie: String?

    public init(initialCookie: String? = nil) {
        self.cookie = initialCookie
    }

    public func loadCookie() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cookie
    }

    public func saveCookie(_ cookie: String) throws {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeWebUsageCookieStoreError.invalidCookie
        }
        lock.lock()
        defer { lock.unlock() }
        self.cookie = trimmed
    }

    public func deleteCookie() throws {
        lock.lock()
        defer { lock.unlock() }
        self.cookie = nil
    }
}
