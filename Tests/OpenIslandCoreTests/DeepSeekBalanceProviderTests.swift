import Testing
import Foundation
@testable import OpenIslandCore

/// Tests for the JSON decoder + cache freshness logic of
/// `DeepSeekBalanceProvider`. The actual `URLSession` round-trip
/// is exercised by integration tests; this suite covers what we
/// can without hitting the network.
@Suite struct DeepSeekBalanceProviderTests {

    @Test
    func decodeHappyPath() throws {
        let payload = """
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "14.20",
                    "granted_balance": "10.00",
                    "topped_up_balance": "4.20"
                }
            ]
        }
        """
        let snapshot = try DeepSeekBalanceProvider.decode(
            data: Data(payload.utf8),
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(snapshot.isAvailable == true)
        #expect(snapshot.currency == "USD")
        #expect(abs(snapshot.totalBalance - 14.20) < 1e-6)
    }

    @Test
    func decodeAccountNotAvailableStillReturnsBalance() throws {
        // is_available=false typically pairs with a $0 balance,
        // but the upstream isn't required to zero it out — we
        // pass the values through and let the UI flag the warning
        // separately.
        let payload = """
        {
            "is_available": false,
            "balance_infos": [
                {"currency": "USD", "total_balance": "0.10"}
            ]
        }
        """
        let snapshot = try DeepSeekBalanceProvider.decode(
            data: Data(payload.utf8)
        )
        #expect(snapshot.isAvailable == false)
        #expect(abs(snapshot.totalBalance - 0.10) < 1e-6)
    }

    @Test
    func decodeNumericTotalBalanceAlsoWorks() throws {
        // Forward-compat: if upstream switches to numeric JSON
        // we must still decode. (Today's API returns strings.)
        let payload = """
        {
            "is_available": true,
            "balance_infos": [
                {"currency": "USD", "total_balance": 12.5}
            ]
        }
        """
        let snapshot = try DeepSeekBalanceProvider.decode(
            data: Data(payload.utf8)
        )
        #expect(abs(snapshot.totalBalance - 12.5) < 1e-6)
    }

    @Test
    func decodeMissingBalanceInfosReturnsZero() throws {
        let payload = """
        {"is_available": true, "balance_infos": []}
        """
        let snapshot = try DeepSeekBalanceProvider.decode(
            data: Data(payload.utf8)
        )
        #expect(snapshot.totalBalance == 0)
        #expect(snapshot.isAvailable == true)
    }

    @Test
    func decodeMalformedRootThrows() {
        let payload = "not json"
        do {
            _ = try DeepSeekBalanceProvider.decode(data: Data(payload.utf8))
            Issue.record("Expected decode to throw on malformed JSON")
        } catch {
            // Expected.
        }
    }

    @Test
    func cachedSnapshotInitiallyNil() async {
        let store = RouterCredentialsStore(backend: InMemoryBackend())
        let provider = DeepSeekBalanceProvider(credentialsStore: store)
        let cached = await provider.cachedSnapshot()
        #expect(cached == nil)
    }

    @Test
    func isStaleTrueWhenCacheEmpty() async {
        let store = RouterCredentialsStore(backend: InMemoryBackend())
        let provider = DeepSeekBalanceProvider(credentialsStore: store)
        let stale = await provider.isStale()
        #expect(stale == true)
    }

    /// Minimal in-memory backend for these unit tests — no
    /// Keychain side effects.
    private final class InMemoryBackend: RouterCredentialsBackend, @unchecked Sendable {
        private var values: [String: String] = [:]
        private let lock = NSLock()
        func setCredential(_ value: String, for account: String) throws {
            lock.lock(); defer { lock.unlock() }
            values[account] = value
        }
        func credential(for account: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[account]
        }
        func deleteCredential(for account: String) throws {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: account)
        }
        func listAccounts() throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(values.keys)
        }
    }
}
