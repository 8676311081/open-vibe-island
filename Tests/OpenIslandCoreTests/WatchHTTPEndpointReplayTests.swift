import Testing
import Foundation
@testable import OpenIslandCore

/// M-1/M-2: nonce-based replay protection on mutating watch
/// endpoints. These tests target the `checkReplayProtection`
/// gate directly — full HTTP-level integration would require
/// driving an NWListener, which is out of scope here.
@Suite struct WatchHTTPEndpointReplayTests {

    private func nowEpochString() -> String {
        String(Int(Date().timeIntervalSince1970))
    }

    private func headers(nonce: String?, timestamp: String?) -> [String: String] {
        var h: [String: String] = [:]
        if let nonce { h["x-oi-nonce"] = nonce }
        if let timestamp { h["x-oi-timestamp"] = timestamp }
        return h
    }

    @Test
    func skipsWhenBothHeadersAbsent() {
        let ep = WatchHTTPEndpoint()
        let result = ep.checkReplayProtection(headers: [:])
        #expect(result == .skipped)
    }

    @Test
    func acceptsValidFreshNonce() {
        let ep = WatchHTTPEndpoint()
        let result = ep.checkReplayProtection(
            headers: headers(nonce: UUID().uuidString, timestamp: nowEpochString())
        )
        #expect(result == .ok)
    }

    @Test
    func rejectsReplayedNonce() {
        let ep = WatchHTTPEndpoint()
        let nonce = UUID().uuidString
        let ts = nowEpochString()

        let first = ep.checkReplayProtection(
            headers: headers(nonce: nonce, timestamp: ts)
        )
        #expect(first == .ok)

        let second = ep.checkReplayProtection(
            headers: headers(nonce: nonce, timestamp: ts)
        )
        #expect(second == .replay)
    }

    @Test
    func rejectsTimestampOutsideSkew() {
        let ep = WatchHTTPEndpoint()
        // 10 minutes in the past — well beyond the 5-min skew
        let oldTs = String(Int(Date().timeIntervalSince1970) - 600)
        let result = ep.checkReplayProtection(
            headers: headers(nonce: UUID().uuidString, timestamp: oldTs)
        )
        #expect(result == .badTimestamp)
    }

    @Test
    func rejectsMalformedTimestamp() {
        let ep = WatchHTTPEndpoint()
        let result = ep.checkReplayProtection(
            headers: headers(nonce: UUID().uuidString, timestamp: "not-a-number")
        )
        #expect(result == .badTimestamp)
    }

    @Test
    func rejectsNonceOnlyWithoutTimestamp() {
        // Half-supplying headers must be treated as malformed,
        // not as soft-skip — otherwise a client can send only
        // the nonce header and bypass timestamp staleness check.
        let ep = WatchHTTPEndpoint()
        let result = ep.checkReplayProtection(
            headers: headers(nonce: UUID().uuidString, timestamp: nil)
        )
        #expect(result == .badTimestamp)
    }

    @Test
    func differentNoncesAcceptedSequentially() {
        let ep = WatchHTTPEndpoint()
        let ts = nowEpochString()
        for _ in 0..<10 {
            let result = ep.checkReplayProtection(
                headers: headers(nonce: UUID().uuidString, timestamp: ts)
            )
            #expect(result == .ok)
        }
    }
}
