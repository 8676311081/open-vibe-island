import Foundation
import os

/// Periodically pulls realtime account-level usage from claude.ai's web
/// API and writes the JSON verbatim onto the statusline cache file
/// (`/tmp/open-island-rl.json`). The existing `ClaudeUsageLoader` already
/// understands the `utilization` field this endpoint returns, so no
/// schema translation is required.
///
/// Failure-mode policy (per DeepSeek review):
/// - any failure → don't touch the cache file. Whatever the statusline
///   wrote last continues to be displayed (with the staleness UI doing
///   its job).
/// - 401/403 → fire `onAuthFailure` so the UI can prompt the user to
///   reconnect (cookie expired or revoked).
/// - 10 consecutive failures (≈ 50 minutes) → fire `onSchemaDrift` so the
///   UI can shift into a "data may be stale" warning posture.
/// - successes reset the consecutive-failure counter.
public final class ClaudeWebUsagePoller: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 300 // 5 minutes
    public static let driftFailureThreshold = 10        // ≈ 50 minutes

    public struct State: Equatable, Sendable {
        public var lastSuccessAt: Date?
        public var lastFailureAt: Date?
        public var lastErrorMessage: String?
        public var consecutiveFailures: Int
        public var resolvedOrganizationID: String?

        public static let empty = State(
            lastSuccessAt: nil,
            lastFailureAt: nil,
            lastErrorMessage: nil,
            consecutiveFailures: 0,
            resolvedOrganizationID: nil
        )

        public var driftSuspected: Bool {
            consecutiveFailures >= ClaudeWebUsagePoller.driftFailureThreshold
        }
    }

    private static let logger = Logger(subsystem: "app.openisland", category: "ClaudeWebUsagePoller")

    private let client: ClaudeWebUsageFetching
    private let cookieStore: ClaudeWebUsageCookieStoring
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "app.openisland.web-usage.poller", qos: .background)

    /// Optional pinned organization ID. If nil, the poller auto-resolves
    /// it via /api/organizations on first run and caches the result on
    /// `state.resolvedOrganizationID`.
    public var pinnedOrganizationID: String?

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onAuthFailure: (@Sendable () -> Void)?
    public var onSchemaDrift: (@Sendable () -> Void)?

    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var stateStorage: State = .empty

    public init(
        client: ClaudeWebUsageFetching = ClaudeWebUsageClient(),
        cookieStore: ClaudeWebUsageCookieStoring = ClaudeWebUsageCookieStore(),
        cacheURL: URL = ClaudeUsageLoader.defaultCacheURL
    ) {
        self.client = client
        self.cookieStore = cookieStore
        self.cacheURL = cacheURL
    }

    public var currentState: State {
        queue.sync { stateStorage }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in
                Task { [weak self] in
                    await self?.refreshNow()
                }
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Triggers an immediate refresh. Safe to call from any thread.
    /// No-op if a refresh is already in flight.
    public func refreshNow() async {
        if !claimSlot() {
            return
        }
        defer { releaseSlot() }

        do {
            let cookie = try cookieStore.loadCookie() ?? ""
            guard !cookie.isEmpty else {
                throw ClaudeWebUsageClientError.missingCookie
            }

            let orgID = try await resolveOrganizationID(cookie: cookie)
            let raw = try await client.fetchUsageRaw(cookie: cookie, organizationID: orgID)

            try writeCache(raw)
            recordSuccess(orgID: orgID)
        } catch {
            recordFailure(error: error)
        }
    }

    // MARK: - Private

    private func claimSlot() -> Bool {
        queue.sync {
            if inFlight { return false }
            inFlight = true
            return true
        }
    }

    private func releaseSlot() {
        queue.async { [weak self] in
            self?.inFlight = false
        }
    }

    private func resolveOrganizationID(cookie: String) async throws -> String {
        if let pinned = pinnedOrganizationID, !pinned.isEmpty {
            return pinned
        }
        if let cached = currentState.resolvedOrganizationID, !cached.isEmpty {
            return cached
        }
        let orgs = try await client.fetchOrganizations(cookie: cookie)
        let preferred = orgs.first { ($0.role ?? "") != "pending" } ?? orgs[0]
        return preferred.id
    }

    private func writeCache(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: cacheURL, options: .atomic)
    }

    private func recordSuccess(orgID: String) {
        mutateState { state in
            state.lastSuccessAt = Date()
            state.lastFailureAt = nil
            state.lastErrorMessage = nil
            state.consecutiveFailures = 0
            state.resolvedOrganizationID = orgID
        }
    }

    private func recordFailure(error: Error) {
        let webError = error as? ClaudeWebUsageClientError
        let message: String
        if let webError {
            message = webError.localizedDescription
        } else {
            message = error.localizedDescription
        }

        Self.logger.warning("usage poll failed: \(message, privacy: .public)")

        var crossedDriftThreshold = false
        var unauthorized = false

        mutateState { state in
            state.lastFailureAt = Date()
            state.lastErrorMessage = message
            state.consecutiveFailures += 1
            if state.consecutiveFailures == Self.driftFailureThreshold {
                crossedDriftThreshold = true
            }
        }

        if case .unauthorized = webError {
            unauthorized = true
        }

        if unauthorized {
            onAuthFailure?()
        }
        if crossedDriftThreshold {
            onSchemaDrift?()
        }
    }

    private func mutateState(_ mutate: (inout State) -> Void) {
        let snapshot: State = queue.sync {
            mutate(&stateStorage)
            return stateStorage
        }
        onStateChange?(snapshot)
    }
}
