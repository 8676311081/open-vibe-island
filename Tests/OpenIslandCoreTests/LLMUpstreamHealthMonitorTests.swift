import Foundation
import Testing
@testable import OpenIslandCore

struct LLMUpstreamHealthMonitorTests {
    @Test
    func emptyMonitorReturnsNilFailureRate() {
        let monitor = LLMUpstreamHealthMonitor()
        #expect(monitor.recentFailureRate() == nil)
        #expect(monitor.sampleCount() == 0)
        // No samples → not degraded (avoid false alarm before any
        // request has flown).
        #expect(!monitor.isDegraded())
    }

    @Test
    func recordsSlideThroughWindow() {
        // Default window size is 10. Record 12 samples; only the
        // last 10 should remain, and the failure-rate computed off
        // those.
        let monitor = LLMUpstreamHealthMonitor(windowSize: 10)
        for _ in 0..<5 { monitor.record(success: true) }
        for _ in 0..<7 { monitor.record(success: false) }
        // After 12 records, the window holds the last 10:
        // 3x success + 7x failure → 70% failure.
        #expect(monitor.sampleCount() == 10)
        let rate = monitor.recentFailureRate() ?? -1
        // Allow a small floating-point cushion.
        #expect(abs(rate - 0.7) < 0.0001)
    }

    @Test
    func degradedRequiresMinimumSamples() {
        let monitor = LLMUpstreamHealthMonitor()
        // 4 failures, 0 successes — 100% failure rate, but below
        // the minimum-samples threshold (5). Must NOT report
        // degraded yet.
        for _ in 0..<4 { monitor.record(success: false) }
        #expect(monitor.recentFailureRate() == 1.0)
        #expect(!monitor.isDegraded())
        // Adding a 5th failure crosses both thresholds.
        monitor.record(success: false)
        #expect(monitor.isDegraded())
    }

    @Test
    func degradedFalseWhenFailureRateUnderEightyPercent() {
        // 8 failures + 3 successes in an 11-sample window → 73%
        // failure. Below the 80% threshold, so degraded must be
        // false even though it's mostly failing.
        let monitor = LLMUpstreamHealthMonitor(windowSize: 11)
        for _ in 0..<8 { monitor.record(success: false) }
        for _ in 0..<3 { monitor.record(success: true) }
        let rate = monitor.recentFailureRate() ?? 0
        #expect(rate > 0.7 && rate < 0.8)
        #expect(!monitor.isDegraded())
    }

    @Test
    func resetClearsWindow() {
        let monitor = LLMUpstreamHealthMonitor()
        for _ in 0..<10 { monitor.record(success: false) }
        #expect(monitor.isDegraded())
        monitor.reset()
        #expect(monitor.sampleCount() == 0)
        #expect(monitor.recentFailureRate() == nil)
        #expect(!monitor.isDegraded())
    }
}
