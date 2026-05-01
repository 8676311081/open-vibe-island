import Foundation
import Testing
import os
@testable import OpenIslandCore

/// `@unchecked Sendable` mailbox that closures running on detached
/// background tasks can write into safely. NSLock is unavailable
/// from async contexts under Swift 6 strict concurrency, so we use
/// OSAllocatedUnfairLock.
private final class WarningSink: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ s: String) { storage.withLock { $0.append(s) } }
    func snapshot() -> [String] { storage.withLock { $0 } }
}

struct RTKTelemetryReaderTests {
    // MARK: - Fixtures

    /// Build a fake `rtk` binary that, when invoked, writes the given
    /// stdout / stderr and exits with the given code. Returns its
    /// path so a fixture-flavored RTKInstallationManager can point
    /// `binaryURL` at it.
    static func makeFakeRtkBinary(
        in dir: URL,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int = 0
    ) throws -> URL {
        let bin = dir.appendingPathComponent("rtk")
        // Hand-roll a bash script that forwards the captured stdout
        // and stderr verbatim to its own descriptors. Use a heredoc
        // with `EOF_OUT` / `EOF_ERR` for deterministic output.
        let escapedOut = stdout.replacingOccurrences(of: "'", with: "'\\''")
        let escapedErr = stderr.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/bash
        printf '%s' '\(escapedOut)'
        printf '%s' '\(escapedErr)' >&2
        exit \(exitCode)
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.path
        )
        return bin
    }

    static func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtk-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build an RTKInstallationManager whose `binaryURL` resolves to
    /// the path inside `dir`. The reader only needs `binaryURL` so
    /// the rest of the manager's plumbing (downloader, sha) is
    /// dummy.
    static func makeManager(
        binaryDir: URL
    ) -> RTKInstallationManager {
        // Plant the binary inside the manager's expected layout —
        // it computes binaryURL = home/.open-island/bin/rtk.
        let home = binaryDir
        return RTKInstallationManager(
            homeDirectory: home,
            archProvider: { "arm64" },
            downloader: { _ in URL(fileURLWithPath: "/dev/null") },
            expectedTarballSHA256: "deadbeef"
        )
    }

    static func makeStore(in dir: URL) -> LLMStatsStore {
        LLMStatsStore(url: dir.appendingPathComponent("llm-stats.json"))
    }

    static let validGainJSON = """
    {
      "summary": {
        "total_commands": 17,
        "total_input": 9876,
        "total_output": 4321,
        "total_saved": 5555,
        "avg_savings_pct": 56.25,
        "total_time_ms": 1234,
        "avg_time_ms": 73
      }
    }
    """

    // MARK: - Happy path

    @Test
    func successPathParsesGainJSONAndPersistsToStore() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(binaryDir: root)
        try FileManager.default.createDirectory(
            at: mgr.openIslandBinDirURL,
            withIntermediateDirectories: true
        )
        _ = try Self.makeFakeRtkBinary(
            in: mgr.openIslandBinDirURL,
            stdout: Self.validGainJSON,
            exitCode: 0
        )
        let store = Self.makeStore(in: root)
        let reader = RTKTelemetryReader(manager: mgr, store: store)

        let result = await reader.tick()

        guard case let .success(summary) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(summary.totalCommands == 17)
        #expect(summary.totalInputTokens == 9876)
        #expect(summary.totalOutputTokens == 4321)
        #expect(summary.totalSavedTokens == 5555)
        #expect(summary.avgSavingsPct == 56.25)
        #expect(summary.totalTimeMs == 1234)
        #expect(summary.avgTimeMs == 73)

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.compressionSummary?.totalSavedTokens == 5555)
    }

    // MARK: - Failure mode 1: binary absent

    @Test
    func binaryAbsentClearsStoreAndReturnsBinaryAbsent() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(binaryDir: root)
        // Don't plant any binary. Pre-seed the store with a stale
        // summary to make sure the reader actively clears it.
        let store = Self.makeStore(in: root)
        await store.recordCompressionSummary(CompressionSummary(
            totalCommands: 99, totalSavedTokens: 1234
        ))

        let reader = RTKTelemetryReader(manager: mgr, store: store)
        let result = await reader.tick()

        #expect(result == .binaryAbsent)
        let snapshot = await store.currentSnapshot()
        #expect(snapshot.compressionSummary == nil)
    }

    // MARK: - Failure mode 2: exec failed (preserve last-known)

    @Test
    func execFailedPreservesLastKnownSummary() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(binaryDir: root)
        try FileManager.default.createDirectory(
            at: mgr.openIslandBinDirURL,
            withIntermediateDirectories: true
        )
        // Binary that exits non-zero (simulating an rtk panic / db
        // lock / etc.).
        _ = try Self.makeFakeRtkBinary(
            in: mgr.openIslandBinDirURL,
            stdout: "",
            stderr: "Error: db locked\n",
            exitCode: 1
        )

        let store = Self.makeStore(in: root)
        let lastKnown = CompressionSummary(
            totalCommands: 42,
            totalSavedTokens: 9999
        )
        await store.recordCompressionSummary(lastKnown)

        let sink = WarningSink()
        let reader = RTKTelemetryReader(
            manager: mgr,
            store: store,
            onWarning: { sink.add($0) }
        )

        let result = await reader.tick()

        guard case let .execFailed(_, exitCode) = result else {
            Issue.record("expected .execFailed, got \(result)")
            return
        }
        #expect(exitCode == 1)

        // Last-known summary stays put — DO NOT clear on transient
        // exec failure.
        let snapshot = await store.currentSnapshot()
        #expect(snapshot.compressionSummary == lastKnown)

        // Warning was raised exactly once.
        let warnings = sink.snapshot()
        #expect(warnings.count == 1)
        #expect((warnings.first ?? "").contains("exit"))
    }

    // MARK: - Failure mode 3: schema invalid (preserve last-known +
    // dedicated user-visible warning)

    @Test
    func schemaInvalidPreservesLastKnownAndRaisesWarning() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(binaryDir: root)
        try FileManager.default.createDirectory(
            at: mgr.openIslandBinDirURL,
            withIntermediateDirectories: true
        )
        // Valid JSON but the wrong shape — RTK has presumably bumped
        // its schema in a release. Reader must not break.
        _ = try Self.makeFakeRtkBinary(
            in: mgr.openIslandBinDirURL,
            stdout: """
            {"summary":{"renamed_field":42, "total_input":9876}}
            """,
            exitCode: 0
        )

        let store = Self.makeStore(in: root)
        let lastKnown = CompressionSummary(
            totalCommands: 7,
            totalSavedTokens: 100
        )
        await store.recordCompressionSummary(lastKnown)

        let sink = WarningSink()
        let reader = RTKTelemetryReader(
            manager: mgr,
            store: store,
            onWarning: { sink.add($0) }
        )

        let result = await reader.tick()

        guard case .schemaInvalid = result else {
            Issue.record("expected .schemaInvalid, got \(result)")
            return
        }

        // Last-known summary survives schema drift.
        let snapshot = await store.currentSnapshot()
        #expect(snapshot.compressionSummary == lastKnown)

        // User-visible warning includes the "schema" / "Open Island"
        // hint so the UI can prompt the user to update.
        let firstMsg = sink.snapshot().first ?? ""
        #expect(firstMsg.contains("schema") || firstMsg.contains("Open Island"))
    }

    // MARK: - Warning dedupe

    @Test
    func consecutiveIdenticalWarningsAreDeduped() async throws {
        let root = try Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let mgr = Self.makeManager(binaryDir: root)
        try FileManager.default.createDirectory(
            at: mgr.openIslandBinDirURL,
            withIntermediateDirectories: true
        )
        _ = try Self.makeFakeRtkBinary(
            in: mgr.openIslandBinDirURL,
            stdout: "",
            stderr: "Error: db locked\n",
            exitCode: 1
        )

        let store = Self.makeStore(in: root)
        let sink = WarningSink()
        let reader = RTKTelemetryReader(
            manager: mgr,
            store: store,
            onWarning: { sink.add($0) }
        )

        // 5 consecutive identical failures → 1 warning surfaced.
        for _ in 0..<5 {
            _ = await reader.tick()
        }

        let count = sink.snapshot().count
        #expect(count == 1, "got \(count) warnings, expected 1 after dedupe")
    }

    // MARK: - Schema parse helper (direct unit, no subprocess)

    @Test
    func parseGainExtractsAllFields() throws {
        let summary = try RTKTelemetryReader.parseGain(Data(Self.validGainJSON.utf8))
        #expect(summary.totalCommands == 17)
        #expect(summary.totalInputTokens == 9876)
        #expect(summary.totalOutputTokens == 4321)
        #expect(summary.totalSavedTokens == 5555)
        #expect(summary.avgSavingsPct == 56.25)
        #expect(summary.totalTimeMs == 1234)
        #expect(summary.avgTimeMs == 73)
        // lastUpdatedAt is "now-ish" — assert plausible (within the
        // last 10 seconds) without making the test flaky.
        #expect(abs(summary.lastUpdatedAt.timeIntervalSinceNow) < 10)
    }

    @Test
    func parseGainIgnoresExtraTopLevelKeysLikeDailyAndWeekly() throws {
        let json = """
        {
          "summary": {
            "total_commands": 1, "total_input": 2, "total_output": 3,
            "total_saved": 4, "avg_savings_pct": 5.0,
            "total_time_ms": 6, "avg_time_ms": 7
          },
          "daily": [{"date":"2026-05-01","commands":1}],
          "weekly": []
        }
        """
        let summary = try RTKTelemetryReader.parseGain(Data(json.utf8))
        #expect(summary.totalCommands == 1)
    }

    // MARK: - Snapshot Codable round-trip (back-compat)

    @Test
    func legacySnapshotWithoutCompressionSummaryDecodesCleanly() throws {
        // Stats.json written before this commit existed: no
        // compressionSummary key. Synthesized Codable should
        // decode it as nil because compressionSummary is Optional.
        let legacyJSON = """
        {"version": 1, "days": {}}
        """
        let snap = try JSONDecoder().decode(
            LLMStatsSnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(snap.compressionSummary == nil)
    }

    @Test
    func snapshotWithCompressionSummaryRoundTrips() throws {
        let original = LLMStatsSnapshot(
            version: 1,
            days: [:],
            compressionSummary: CompressionSummary(
                totalCommands: 11,
                totalInputTokens: 22,
                totalOutputTokens: 33,
                totalSavedTokens: 44,
                avgSavingsPct: 55.5,
                totalTimeMs: 66,
                avgTimeMs: 77,
                lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(LLMStatsSnapshot.self, from: data)

        #expect(round.compressionSummary == original.compressionSummary)
    }

    // MARK: - Lifecycle

    @Test
    func startIsIdempotent() async {
        let root = try! Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = Self.makeManager(binaryDir: root)
        let store = Self.makeStore(in: root)
        // Use a long interval so the loop doesn't actually fire
        // during the test. We're only checking start/stop logic.
        let reader = RTKTelemetryReader(manager: mgr, store: store, interval: 3600)
        reader.start()
        reader.start()  // second call must be a no-op
        #expect(reader.isRunning)
        reader.stop()
        #expect(!reader.isRunning)
    }
}
