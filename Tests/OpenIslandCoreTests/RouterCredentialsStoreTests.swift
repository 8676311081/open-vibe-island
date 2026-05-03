import Foundation
import Testing
@testable import OpenIslandCore

/// In-memory backend for unit tests. Lives in this test file (not
/// production code) because production has no use for an ephemeral
/// store — only the keychain-backed live() backend ships. NSLock so
/// concurrent tests aren't an issue if a future test exercises
/// parallel reads/writes.
private final class InMemoryCredentialsBackend: RouterCredentialsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func setCredential(_ value: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }

    func credential(for account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    func deleteCredential(for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }

    func listAccounts() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}

struct RouterCredentialsStoreTests {
    @Test
    func setAndReadCredentialRoundtrips() throws {
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        try store.setCredential("sk-test-deepseek-123", for: "deepseek")
        #expect(try store.credential(for: "deepseek") == "sk-test-deepseek-123")
    }

    @Test
    func readMissingCredentialReturnsNil() throws {
        // Critical: the read path must NOT throw when the account is
        // simply absent. UI code uses this to ask "does the user have
        // a DeepSeek key configured?" and a thrown error would force
        // every caller into a try/catch dance.
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        #expect(try store.credential(for: "absent") == nil)
    }

    @Test
    func setSecondTimeOverwritesValue() throws {
        // When the user re-enters their key in the routing pane, the
        // old key must be replaced — not left alongside as a stale
        // duplicate. KeychainCredentialsBackend's update-then-add
        // path encodes this; the in-memory backend mirrors it via
        // dict assignment.
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        try store.setCredential("v1", for: "deepseek")
        try store.setCredential("v2", for: "deepseek")
        #expect(try store.credential(for: "deepseek") == "v2")
    }

    @Test
    func deleteCredentialRemoves() throws {
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        try store.setCredential("v", for: "deepseek")
        try store.deleteCredential(for: "deepseek")
        #expect(try store.credential(for: "deepseek") == nil)
    }

    @Test
    func deleteMissingIsIdempotent() throws {
        // Caller intent is "make sure this account has no credential" —
        // already-absent satisfies that. KeychainCredentialsBackend
        // explicitly maps `errSecItemNotFound` → success for the same
        // reason.
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        try store.deleteCredential(for: "absent") // must not throw
    }

    @Test
    func listReturnsSortedAccountNames() throws {
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        try store.setCredential("k1", for: "zeta")
        try store.setCredential("k2", for: "alpha")
        try store.setCredential("k3", for: "mu")
        #expect(try store.listAccounts() == ["alpha", "mu", "zeta"])
    }

    @Test
    func hasCredentialReflectsSetAndDelete() throws {
        let store = RouterCredentialsStore(backend: InMemoryCredentialsBackend())
        #expect(!store.hasCredential(for: "deepseek"))
        try store.setCredential("k", for: "deepseek")
        #expect(store.hasCredential(for: "deepseek"))
        try store.deleteCredential(for: "deepseek")
        #expect(!store.hasCredential(for: "deepseek"))
    }
}
