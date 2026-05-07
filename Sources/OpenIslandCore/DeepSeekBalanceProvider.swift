import Foundation
import os

/// DeepSeek's documented balance endpoint:
/// `GET https://api.deepseek.com/user/balance` with
/// `Authorization: Bearer <api-key>`. Codex's review pointed out
/// that the endpoint we previously assumed (`/v1/dashboard/billing`)
/// was wrong; this one is the canonical one.
///
/// Response shape (excerpt — fields we read):
/// ```
/// {
///   "is_available": true,
///   "balance_infos": [
///     {
///       "currency": "USD",
///       "total_balance": "14.20",
///       "granted_balance": "10.00",
///       "topped_up_balance": "4.20"
///     }
///   ]
/// }
/// ```
public struct DeepSeekBalanceSnapshot: Equatable, Sendable {
    /// Total available balance in `currency` (typically USD).
    public var totalBalance: Double
    /// Currency reported by DeepSeek. We don't convert; spend UI
    /// renders `currency` literal next to the amount so a non-USD
    /// account isn't quietly mis-labeled.
    public var currency: String
    /// Whether the upstream considers the account active. False
    /// means the user is locked out — the spend UI should warn.
    public var isAvailable: Bool
    /// When this snapshot was fetched. Used both for cache TTL
    /// decisions and for displaying "as of <time>" in the UI when
    /// stale.
    public var fetchedAt: Date

    public init(
        totalBalance: Double,
        currency: String,
        isAvailable: Bool,
        fetchedAt: Date
    ) {
        self.totalBalance = totalBalance
        self.currency = currency
        self.isAvailable = isAvailable
        self.fetchedAt = fetchedAt
    }
}

public enum DeepSeekBalanceError: Error, Sendable {
    case missingCredential
    case httpError(status: Int, body: String)
    case decodeFailed(reason: String)
}

/// Read the DeepSeek account balance. Caches the most recent
/// successful snapshot in memory; callers can ask for the cached
/// value without forcing a network round-trip.
///
/// **Polling discipline.** Codex was explicit that we should NOT
/// hit `/user/balance` on every spend-pane render or every app
/// launch. The provider exposes a manual `refresh()` (UI button
/// / pane onAppear once-per-TTL) and an in-memory cache with a
/// 15-minute TTL. The pre-three-port design tried to poll every
/// minute; that pattern is removed here.
public actor DeepSeekBalanceProvider {
    /// Cache freshness window. After this elapsed since the last
    /// successful fetch, `current()` will trigger a background
    /// refresh on the next access. Manual `refresh()` overrides.
    public static let defaultCacheTTL: TimeInterval = 900  // 15 min

    private let session: URLSession
    private let endpointURL: URL
    private let credentialAccount: String
    private let credentialsStore: RouterCredentialsStore
    private let cacheTTL: TimeInterval
    private static let logger = Logger(
        subsystem: "app.openisland",
        category: "DeepSeekBalance"
    )

    private var cached: DeepSeekBalanceSnapshot?
    private var inFlight: Task<DeepSeekBalanceSnapshot, Error>?

    public init(
        credentialsStore: RouterCredentialsStore,
        credentialAccount: String = "deepseek",
        endpointURL: URL = URL(string: "https://api.deepseek.com/user/balance")!,
        session: URLSession = URLSession(configuration: .ephemeral),
        cacheTTL: TimeInterval = defaultCacheTTL
    ) {
        self.credentialsStore = credentialsStore
        self.credentialAccount = credentialAccount
        self.endpointURL = endpointURL
        self.session = session
        self.cacheTTL = cacheTTL
    }

    /// The most recent snapshot if any. Does NOT trigger a fetch.
    /// UI uses this for synchronous renders + reads `isStale` to
    /// decide whether to show a "refreshing…" indicator.
    public func cachedSnapshot() -> DeepSeekBalanceSnapshot? {
        cached
    }

    /// True when the cache is older than `cacheTTL` (or empty).
    /// The UI uses this to decide whether to fire a background
    /// `refresh()` on appear.
    public func isStale(now: Date = Date()) -> Bool {
        guard let cached else { return true }
        return now.timeIntervalSince(cached.fetchedAt) > cacheTTL
    }

    /// Force a refresh from upstream. Coalesces concurrent callers
    /// onto a single in-flight request so a fast SwiftUI redraw +
    /// onAppear race doesn't fire two parallel requests.
    @discardableResult
    public func refresh() async throws -> DeepSeekBalanceSnapshot {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<DeepSeekBalanceSnapshot, Error> {
            try await fetch()
        }
        inFlight = task
        defer { inFlight = nil }
        let snapshot = try await task.value
        cached = snapshot
        return snapshot
    }

    private func fetch() async throws -> DeepSeekBalanceSnapshot {
        guard let key = try? credentialsStore.credential(for: credentialAccount),
              !key.isEmpty
        else {
            Self.logger.notice("DeepSeek balance fetch skipped — no credential for account \(self.credentialAccount, privacy: .public)")
            throw DeepSeekBalanceError.missingCredential
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Self.logger.warning("DeepSeek balance fetch HTTP \(status, privacy: .public): \(body, privacy: .public)")
            throw DeepSeekBalanceError.httpError(status: status, body: body)
        }
        return try Self.decode(data: data, fetchedAt: Date())
    }

    /// Decode `/user/balance` JSON. Public + static so unit tests
    /// can exercise it without a live `URLSession`.
    public static func decode(
        data: Data,
        fetchedAt: Date = Date()
    ) throws -> DeepSeekBalanceSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DeepSeekBalanceError.decodeFailed(reason: "root is not an object")
        }
        let isAvailable = root["is_available"] as? Bool ?? false
        let infos = root["balance_infos"] as? [[String: Any]] ?? []
        // We pick the first entry. Multi-currency accounts would
        // surface multiple here; today's UI is single-line and
        // single-currency, so this matches what we render.
        guard let first = infos.first else {
            return DeepSeekBalanceSnapshot(
                totalBalance: 0,
                currency: "USD",
                isAvailable: isAvailable,
                fetchedAt: fetchedAt
            )
        }
        let currency = first["currency"] as? String ?? "USD"
        // DeepSeek returns balances as JSON strings — "14.20" not 14.2.
        // Tolerate both forms in case that changes upstream.
        let totalRaw = first["total_balance"]
        let total: Double
        if let s = totalRaw as? String, let parsed = Double(s) {
            total = parsed
        } else if let n = totalRaw as? Double {
            total = n
        } else if let i = totalRaw as? Int {
            total = Double(i)
        } else {
            total = 0
        }
        return DeepSeekBalanceSnapshot(
            totalBalance: total,
            currency: currency,
            isAvailable: isAvailable,
            fetchedAt: fetchedAt
        )
    }
}
