import Foundation

/// Tracks recent success/failure outcomes from `LLMProxyServer`'s
/// upstream forwards, so `ModelRoutingPane` can surface a "your
/// active profile's upstream looks broken" banner without polling
/// the entire stats subsystem.
///
/// Scope is intentionally narrow:
///   - Tracks the LAST `windowSize` outcomes (default 10) — fixed
///     ring buffer, not per-host.
///   - "Health" is a function of the current window only. Switching
///     the active profile resets the window (call `reset()` from
///     `AppModel.setActiveUpstreamProfile`) — the previous
///     provider's results have nothing to say about the new
///     upstream.
///   - Pure in-memory. App restart clears the window.
///
/// Concurrency: `final class + NSLock`, same rationale as
/// `UpstreamProfileStore` — proxy hot path calls `record(success:)`
/// from a sync context (`URLSession` delegate / NWConnection
/// callbacks); making this an actor would force `await` through
/// the dispatch chain.
public final class LLMUpstreamHealthMonitor: @unchecked Sendable {
    public static let defaultWindowSize = 10
    /// Pane shows the degradation banner only after we have at
    /// least this many samples — otherwise a single 5xx on app
    /// launch would flag the entire upstream red.
    public static let minimumSamplesForReadout = 5
    /// Failure-rate threshold above which the upstream is
    /// considered degraded enough to surface to the user.
    public static let degradedFailureRateThreshold = 0.8

    private let windowSize: Int
    private let lock = NSLock()
    private var window: [Bool] = [] // true = success, false = failure

    public init(windowSize: Int = defaultWindowSize) {
        self.windowSize = max(1, windowSize)
    }

    /// Append the latest outcome to the ring buffer. Failures here
    /// include both upstream 4xx/5xx responses AND network-layer
    /// errors (DNS, TLS, timeout).
    public func record(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        window.append(success)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }
    }

    /// Drop all history. Called on profile switch — the new
    /// upstream's behavior is unrelated to the old one's.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        window.removeAll(keepingCapacity: true)
    }

    /// `[0.0, 1.0]` failure rate over the current window. `nil`
    /// when the window is empty (caller should treat as "no signal
    /// yet" rather than zero failures).
    public func recentFailureRate() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard !window.isEmpty else { return nil }
        let failures = window.filter { !$0 }.count
        return Double(failures) / Double(window.count)
    }

    public func sampleCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return window.count
    }

    /// True when there are enough samples AND the failure rate
    /// crosses `degradedFailureRateThreshold`. Used by the routing
    /// pane to decide whether to show the warning banner.
    public func isDegraded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard window.count >= Self.minimumSamplesForReadout else { return false }
        let failures = window.filter { !$0 }.count
        return Double(failures) / Double(window.count) >= Self.degradedFailureRateThreshold
    }
}
