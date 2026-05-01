import Foundation

/// Polls `<rtk binary> gain --format json` on a fixed interval and
/// pushes the parsed `CompressionSummary` into `LLMStatsStore`.
///
/// Why polling and not fs_events on a jsonl file:
///   The original Phase 3 design tee'd RTK's `[rtk] origTok→compTok
///   tokens (N% saved)` stderr lines into a wrapper-managed
///   `~/.open-island/rtk-stats.jsonl` and watched it via fs_events.
///   RTK 0.38.0 no longer emits those stderr summary lines; instead
///   it persists every invocation's savings into its own SQLite at
///   `~/Library/Application Support/rtk/history.db` and exposes a
///   query CLI (`rtk gain`). Mirroring against an authoritative
///   query is more robust than parsing a stderr format that the
///   upstream may keep evolving, so this reader spawns `rtk gain
///   --format json` on a cadence and trusts that view.
///
/// Cadence:
///   This commit ships a fixed 60-second interval. A foreground
///   "tab visible" mode that bumps to ~5 seconds is intentionally
///   deferred to a follow-up commit — keeping the reader's lifecycle
///   simple while we settle the schema.
public final class RTKTelemetryReader: @unchecked Sendable {
    public static let defaultPollInterval: TimeInterval = 60

    /// Discriminated outcome for one poll cycle. Each case maps to a
    /// distinct production failure mode with its own recovery
    /// behavior — see `tickOnce` for the actual policy.
    public enum PollResult: Sendable, Equatable {
        case success(CompressionSummary)
        /// RTK binary not at the expected path. Reader silently
        /// clears the store's `compressionSummary`. UI renders "—".
        case binaryAbsent
        /// `rtk gain` exited non-zero. Last-known summary is
        /// preserved in the store (do NOT clear) so a transient
        /// crash doesn't make the UI jump 12345 → — → 12345.
        case execFailed(stderr: String, exitCode: Int32)
        /// stdout was JSON but didn't match the expected shape (RTK
        /// presumably bumped its schema in an upgrade). Last-known
        /// summary preserved; an explicit warning fires so the UI
        /// can prompt "RTK schema changed, please update Open
        /// Island".
        case schemaInvalid(reason: String)
    }

    public typealias WarningHandler = @Sendable (String) -> Void

    private let manager: RTKInstallationManager
    private let store: LLMStatsStore
    private let interval: TimeInterval
    private let onWarning: WarningHandler?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// Dedupe consecutive identical warnings — a stale-schema RTK
    /// would otherwise spam the user every poll period.
    private var lastWarning: String?

    public init(
        manager: RTKInstallationManager,
        store: LLMStatsStore,
        interval: TimeInterval = defaultPollInterval,
        onWarning: WarningHandler? = nil
    ) {
        self.manager = manager
        self.store = store
        self.interval = interval
        self.onWarning = onWarning
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != nil
    }

    /// Idempotent. Starts a background task that fires `tick()`
    /// immediately, then on the configured cadence. The first tick
    /// is synchronous-ish (still off the main thread, but no sleep
    /// before it) so UI has data without a 60-second initial blank.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let interval = self.interval
        weak var weakSelf = self
        task = Task.detached(priority: .background) {
            _ = await weakSelf?.tick()
            while !Task.isCancelled {
                let nanos = UInt64(max(interval, 0.001) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                _ = await weakSelf?.tick()
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    /// Single poll cycle. Public for unit testing — tests don't want
    /// to wait 60 seconds between assertions.
    @discardableResult
    public func tick() async -> PollResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: manager.binaryURL.path) else {
            await store.clearCompressionSummary()
            return .binaryAbsent
        }
        let (stdout, stderr, exitCode) = Self.runGain(binaryURL: manager.binaryURL)
        guard exitCode == 0 else {
            warnDeduped("RTK gain exited \(exitCode): \(String(stderr.prefix(200)))")
            return .execFailed(stderr: stderr, exitCode: exitCode)
        }
        do {
            let summary = try Self.parseGain(stdout)
            await store.recordCompressionSummary(summary)
            return .success(summary)
        } catch {
            warnDeduped(
                "RTK gain returned an unexpected schema. "
                    + "Open Island may need an update. (\(error.localizedDescription))"
            )
            return .schemaInvalid(reason: "\(error)")
        }
    }

    private func warnDeduped(_ msg: String) {
        lock.lock()
        let isNew = (lastWarning != msg)
        lastWarning = msg
        lock.unlock()
        if isNew { onWarning?(msg) }
    }

    // MARK: - Subprocess

    /// Spawn `<binaryURL> gain --format json`, return (stdout,
    /// stderr, exit). Blocking — caller is on a detached background
    /// Task, so the wait doesn't pin a useful thread.
    private static func runGain(binaryURL: URL) -> (Data, String, Int32) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["gain", "--format", "json"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (Data(), "spawn failed: \(error)", -1)
        }
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (outData, errStr, process.terminationStatus)
    }

    /// RTK gain JSON schema (verified by hand on rtk 0.38.0):
    ///
    /// ```
    /// { "summary": {
    ///     "total_commands": Int,
    ///     "total_input": Int,
    ///     "total_output": Int,
    ///     "total_saved": Int,
    ///     "avg_savings_pct": Double,
    ///     "total_time_ms": Int,
    ///     "avg_time_ms": Int
    ///   }, ... extra keys (daily, weekly, ...) ignored ... }
    /// ```
    ///
    /// `lastUpdatedAt` is added by us (RTK doesn't ship it).
    static func parseGain(_ data: Data) throws -> CompressionSummary {
        struct Wire: Decodable {
            struct Summary: Decodable {
                let totalCommands: Int
                let totalInput: Int
                let totalOutput: Int
                let totalSaved: Int
                let avgSavingsPct: Double
                let totalTimeMs: Int
                let avgTimeMs: Int
            }
            let summary: Summary
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wire = try decoder.decode(Wire.self, from: data)
        let s = wire.summary
        return CompressionSummary(
            totalCommands: s.totalCommands,
            totalInputTokens: s.totalInput,
            totalOutputTokens: s.totalOutput,
            totalSavedTokens: s.totalSaved,
            avgSavingsPct: s.avgSavingsPct,
            totalTimeMs: s.totalTimeMs,
            avgTimeMs: s.avgTimeMs,
            lastUpdatedAt: Date()
        )
    }
}
