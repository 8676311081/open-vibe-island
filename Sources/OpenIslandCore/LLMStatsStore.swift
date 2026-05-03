import Foundation

// MARK: - Snapshot model

/// One client's worth of activity on one calendar day. The shape matches
/// what `IslandPanelView` and the LLM Spend control center pane consume.
public struct LLMDayBucket: Codable, Sendable, Equatable {
    public var turns: Int
    public var tokensIn: Int
    public var tokensOut: Int
    /// Subset of `tokensIn` that was uncached prompt input (Anthropic
    /// `input_tokens` / OpenAI `prompt_tokens` minus cached). Stored
    /// explicitly so cache-hit math can distinguish a fresh bucket
    /// with no caches yet (`inputTokens == tokensIn > 0`, hit ratio
    /// = 0%) from a legacy bucket where the breakdown was never
    /// recorded (all three breakdown fields == 0 yet `tokensIn > 0`,
    /// hit ratio = nil → "—").
    public var inputTokens: Int
    /// Subset of `tokensIn` that came from cache reads (Anthropic
    /// `cache_read_input_tokens` / OpenAI `cached_tokens`).
    public var cacheReadTokens: Int
    /// Subset of `tokensIn` that came from cache writes / creation
    /// (Anthropic `cache_creation_input_tokens`).
    public var cacheCreationTokens: Int
    public var costUsd: Double
    /// Turns whose model wasn't in the pricing table. Tokens are still
    /// counted in tokensIn/tokensOut, but cost couldn't be computed.
    /// UI uses this to distinguish `$0.00` (genuinely cheap) from `—`
    /// (we don't know how to price this model — table needs updating).
    public var unpricedTurns: Int
    /// Per-model turn count. Key is the model ID as seen by the
    /// observer (after body rewrite — e.g. `deepseek-v4-pro`,
    /// `claude-sonnet-4-5`). Optional on decode → `[:]` for
    /// legacy buckets.
    public var modelTurns: [String: Int]
    /// Per-model accumulated cost. Keys match `modelTurns`. Sum
    /// across keys equals `costUsd` (minus unpriced models, which
    /// contribute $0). Optional on decode → `[:]` for legacy
    /// buckets.
    public var modelCosts: [String: Double]
    /// Per-model accumulated tokens (in + cache_write + cache_read + out).
    /// Mirrors how `tokensIn + tokensOut` is summed at the bucket level
    /// for the bySource row, but split by model so the byModel row can
    /// display the same metric. Sum across keys equals
    /// `tokensIn + tokensOut` for buckets recorded after this field
    /// landed; legacy buckets decode to `[:]` and the UI shows "—".
    public var modelTokens: [String: Int]
    /// Per-model breakdown of the three components that make up the
    /// cache-hit ratio (cacheRead / (input + cacheRead + cacheCreation)).
    /// Each is the sum of `usage.input` / `usage.cacheRead` /
    /// `usage.cacheWrite` (DeepSeek's prompt_cache_hit_tokens lands in
    /// cacheRead via the OpenAI-style fallback in LLMUsageExtraction).
    /// Legacy buckets decode to `[:]` so the byModel row falls back to
    /// "—" until new turns rebuild it.
    public var modelInputTokens: [String: Int]
    public var modelCacheReadTokens: [String: Int]
    public var modelCacheCreationTokens: [String: Int]
    public var duplicateToolCalls: Int
    /// Sum of estimated tokens for tools the model declared in
    /// `tools[]` but never invoked during the turn. Estimated from
    /// `LLMRequestAnalyzer` + `LLMTokenEstimator` — approximate, used
    /// only for visibility ("you carried 3000 tokens of schema for
    /// nothing"). Optional on decode → defaults to 0 for legacy
    /// buckets.
    public var unusedToolTokensWasted: Int
    public var lastWarning: LLMDuplicateWarning?
    public var lastUpdatedAt: Date?

    public init(
        turns: Int = 0,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        costUsd: Double = 0,
        unpricedTurns: Int = 0,
        modelTurns: [String: Int] = [:],
        modelCosts: [String: Double] = [:],
        modelTokens: [String: Int] = [:],
        modelInputTokens: [String: Int] = [:],
        modelCacheReadTokens: [String: Int] = [:],
        modelCacheCreationTokens: [String: Int] = [:],
        duplicateToolCalls: Int = 0,
        unusedToolTokensWasted: Int = 0,
        lastWarning: LLMDuplicateWarning? = nil,
        lastUpdatedAt: Date? = nil
    ) {
        self.turns = turns
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUsd = costUsd
        self.unpricedTurns = unpricedTurns
        self.modelTurns = modelTurns
        self.modelCosts = modelCosts
        self.modelTokens = modelTokens
        self.modelInputTokens = modelInputTokens
        self.modelCacheReadTokens = modelCacheReadTokens
        self.modelCacheCreationTokens = modelCacheCreationTokens
        self.duplicateToolCalls = duplicateToolCalls
        self.unusedToolTokensWasted = unusedToolTokensWasted
        self.lastWarning = lastWarning
        self.lastUpdatedAt = lastUpdatedAt
    }

    enum CodingKeys: String, CodingKey {
        case turns, tokensIn, tokensOut
        case inputTokens, cacheReadTokens, cacheCreationTokens
        case costUsd, unpricedTurns
        case modelTurns, modelCosts, modelTokens
        case modelInputTokens, modelCacheReadTokens, modelCacheCreationTokens
        case duplicateToolCalls
        case unusedToolTokensWasted
        case lastWarning, lastUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        unpricedTurns = try c.decodeIfPresent(Int.self, forKey: .unpricedTurns) ?? 0
        modelTurns = try c.decodeIfPresent([String: Int].self, forKey: .modelTurns) ?? [:]
        modelCosts = try c.decodeIfPresent([String: Double].self, forKey: .modelCosts) ?? [:]
        modelTokens = try c.decodeIfPresent([String: Int].self, forKey: .modelTokens) ?? [:]
        modelInputTokens = try c.decodeIfPresent([String: Int].self, forKey: .modelInputTokens) ?? [:]
        modelCacheReadTokens = try c.decodeIfPresent([String: Int].self, forKey: .modelCacheReadTokens) ?? [:]
        modelCacheCreationTokens = try c.decodeIfPresent([String: Int].self, forKey: .modelCacheCreationTokens) ?? [:]
        duplicateToolCalls = try c.decodeIfPresent(Int.self, forKey: .duplicateToolCalls) ?? 0
        unusedToolTokensWasted = try c.decodeIfPresent(Int.self, forKey: .unusedToolTokensWasted) ?? 0
        lastWarning = try c.decodeIfPresent(LLMDuplicateWarning.self, forKey: .lastWarning)
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
    }
}

public extension LLMDayBucket {
    /// Cache-hit ratio in `[0, 1]`, or `nil` if no breakdown is
    /// recorded for this bucket. Returns `nil` when
    /// `inputTokens + cacheReadTokens + cacheCreationTokens == 0`,
    /// which covers two cases:
    ///
    ///   1. **Legacy bucket** — written before the breakdown fields
    ///      existed. `tokensIn > 0` but no component is populated;
    ///      the breakdown is unrecoverable.
    ///   2. **Empty bucket** — no traffic at all. UI normally
    ///      filters these before calling, but `nil` is the honest
    ///      answer either way.
    ///
    /// UI must render `nil` as `—` rather than `0%`, since `0%` is a
    /// real and very different signal (lots of traffic, none cached).
    var cacheHitRatio: Double? {
        let denom = inputTokens + cacheReadTokens + cacheCreationTokens
        guard denom > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denom)
    }
}

/// Cache-hit aggregation across multiple buckets. Sums the breakdown
/// components and applies the same nil-on-zero-denominator rule —
/// so a range that contains *only* legacy buckets returns `nil`,
/// while a mixed range returns the ratio over the buckets that
/// recorded a breakdown.
public enum LLMCacheHitAggregator {
    public static func ratio<S: Sequence>(of buckets: S) -> Double?
    where S.Element == LLMDayBucket {
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        for b in buckets {
            input += b.inputTokens
            cacheRead += b.cacheReadTokens
            cacheCreation += b.cacheCreationTokens
        }
        let denom = input + cacheRead + cacheCreation
        guard denom > 0 else { return nil }
        return Double(cacheRead) / Double(denom)
    }
}

public struct LLMDuplicateWarning: Codable, Sendable, Equatable {
    public let toolName: String
    public let at: Date
    public init(toolName: String, at: Date) {
        self.toolName = toolName
        self.at = at
    }
}

/// Cross-client compression telemetry sourced from RTK's own
/// `~/Library/Application Support/rtk/history.db`, surfaced via
/// `rtk gain --format json`. Stored as a SINGLE top-level field on
/// `LLMStatsSnapshot` (not inside per-day per-client `LLMDayBucket`s)
/// because RTK accumulates globally — no per-day, no per-client
/// breakdown. Trying to fan it out into `days[date][client]` would
/// invent attribution data we don't have.
///
/// Keys match what RTK emits, just camelCased. `lastUpdatedAt` is
/// Open Island's own bookkeeping — RTK doesn't ship it. Optional on
/// decode so legacy `stats.json` files that pre-date this field
/// round-trip cleanly.
public struct CompressionSummary: Codable, Sendable, Equatable {
    public var totalCommands: Int
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalSavedTokens: Int
    public var avgSavingsPct: Double
    public var totalTimeMs: Int
    public var avgTimeMs: Int
    public var lastUpdatedAt: Date

    public init(
        totalCommands: Int = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalSavedTokens: Int = 0,
        avgSavingsPct: Double = 0,
        totalTimeMs: Int = 0,
        avgTimeMs: Int = 0,
        lastUpdatedAt: Date = Date()
    ) {
        self.totalCommands = totalCommands
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalSavedTokens = totalSavedTokens
        self.avgSavingsPct = avgSavingsPct
        self.totalTimeMs = totalTimeMs
        self.avgTimeMs = avgTimeMs
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// On-disk snapshot. `days` is keyed by `yyyy-MM-dd` (local time) →
/// client raw value → bucket. `compressionSummary` is the single
/// top-level field for RTK telemetry — see `CompressionSummary` for
/// the no-per-day-no-per-client rationale. Bumping `version` is the
/// migration hook.
public struct LLMStatsSnapshot: Codable, Sendable, Equatable {
    public var version: Int
    public var days: [String: [String: LLMDayBucket]]
    /// Optional: nil when RTK isn't installed or hasn't been polled
    /// yet. Synthesized Codable on Optional uses `decodeIfPresent`,
    /// so legacy `stats.json` files (no `compressionSummary` key)
    /// round-trip cleanly.
    public var compressionSummary: CompressionSummary?

    public init(
        version: Int = 1,
        days: [String: [String: LLMDayBucket]] = [:],
        compressionSummary: CompressionSummary? = nil
    ) {
        self.version = version
        self.days = days
        self.compressionSummary = compressionSummary
    }
}

// MARK: - Store

/// Thread-safe owner of `llm-stats.json`. The proxy hot path drops events
/// onto the actor; the actor coalesces them into the snapshot and
/// persists. Every mutation triggers an atomic write
/// (`Data.write(_:options:.atomic)` writes to a `.tmp` sibling and
/// renames into place — exactly the contract the spec asked for).
public actor LLMStatsStore {
    public let url: URL
    private(set) var snapshot: LLMStatsSnapshot
    private var recentToolUses: [ToolUseRecord] = []
    /// Per-client most-recent context fill ratio (0.0…1.0).
    /// **In-memory only** — never persisted. Resets to empty on
    /// every app restart, which is correct: this is a "right now"
    /// signal driving the pill/banner colors, not historical
    /// analytics. Keys are present only when we have an upstream
    /// usage event AND a known context limit for the model.
    private var contextFillByClient: [LLMClient: Double] = [:]

    private struct ToolUseRecord {
        let client: LLMClient
        let name: String
        let inputHash: String
        let at: Date
    }

    public static let duplicateWindow: TimeInterval = 5 * 60

    public init(url: URL = LLMProxySupportPaths.statsFileURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let loaded = try? Self.decoder.decode(LLMStatsSnapshot.self, from: data) {
            self.snapshot = loaded
        } else {
            self.snapshot = LLMStatsSnapshot()
        }
    }

    public func currentSnapshot() -> LLMStatsSnapshot { snapshot }

    /// `costUsd` may be nil — meaning we counted the tokens but didn't
    /// have a pricing row for this model. Bucket records a tick on
    /// `unpricedTurns` so the UI can show `—` and you know the
    /// pricing table is stale.
    public func recordRequestCompletion(
        date: Date = Date(),
        client: LLMClient,
        model: String? = nil,
        usage: TokenUsage,
        costUsd: Double?,
        unusedToolTokensWasted: Int = 0
    ) {
        let key = Self.dayKey(for: date)
        var dayBuckets = snapshot.days[key] ?? [:]
        var bucket = dayBuckets[client.rawValue] ?? LLMDayBucket()
        bucket.turns += 1
        bucket.tokensIn += usage.input + usage.cacheWrite + usage.cacheRead
        bucket.inputTokens += usage.input
        bucket.cacheReadTokens += usage.cacheRead
        bucket.cacheCreationTokens += usage.cacheWrite
        bucket.tokensOut += usage.output
        bucket.unusedToolTokensWasted += unusedToolTokensWasted
        if let costUsd {
            bucket.costUsd += costUsd
        } else {
            bucket.unpricedTurns += 1
        }
        if let model {
            bucket.modelTurns[model, default: 0] += 1
            if let costUsd {
                bucket.modelCosts[model, default: 0] += costUsd
            }
            // Match the bucket-level tokens metric (in + cache_write + cache_read + out)
            // so the byModel row totals to the bySource row.
            bucket.modelTokens[model, default: 0] += usage.input + usage.cacheWrite + usage.cacheRead + usage.output
            // Mirror the per-bucket cache-hit components, scoped by
            // model so the byModel row can compute the same ratio.
            bucket.modelInputTokens[model, default: 0] += usage.input
            bucket.modelCacheReadTokens[model, default: 0] += usage.cacheRead
            bucket.modelCacheCreationTokens[model, default: 0] += usage.cacheWrite
        }
        bucket.lastUpdatedAt = date
        dayBuckets[client.rawValue] = bucket
        snapshot.days[key] = dayBuckets
        persist()
    }

    /// Returns true if `(client, name, inputHash)` was already recorded
    /// inside the rolling 5-minute window — i.e. the model just made
    /// the same tool call again. Always records the new occurrence.
    public func recordToolUse(
        client: LLMClient,
        name: String,
        inputHash: String,
        at: Date = Date()
    ) -> Bool {
        let cutoff = at.addingTimeInterval(-Self.duplicateWindow)
        recentToolUses.removeAll { $0.at < cutoff }
        let isDuplicate = recentToolUses.contains {
            $0.client == client && $0.name == name && $0.inputHash == inputHash
        }
        recentToolUses.append(
            ToolUseRecord(client: client, name: name, inputHash: inputHash, at: at)
        )
        return isDuplicate
    }

    public func recordDuplicateWarning(
        date: Date = Date(),
        client: LLMClient,
        toolName: String
    ) {
        let key = Self.dayKey(for: date)
        var dayBuckets = snapshot.days[key] ?? [:]
        var bucket = dayBuckets[client.rawValue] ?? LLMDayBucket()
        bucket.duplicateToolCalls += 1
        bucket.lastWarning = LLMDuplicateWarning(toolName: toolName, at: date)
        dayBuckets[client.rawValue] = bucket
        snapshot.days[key] = dayBuckets
        persist()
    }

    public func clearToday(date: Date = Date()) {
        let key = Self.dayKey(for: date)
        snapshot.days.removeValue(forKey: key)
        persist()
    }

    // MARK: - Context fill (in-memory, not persisted)

    /// Record the latest seen context fill ratio for a client. Called
    /// by `LLMUsageObserver` once per request, after the upstream's
    /// `message_start` (Anthropic) / equivalent first-usage event has
    /// landed. Caller is responsible for clamping to `[0, 1]`.
    public func recordContextFill(client: LLMClient, ratio: Double) {
        contextFillByClient[client] = ratio
    }

    /// Snapshot of all clients with a recorded fill ratio.
    public func currentContextFills() -> [LLMClient: Double] {
        contextFillByClient
    }

    /// Replace the cross-client compression summary. Called by
    /// `RTKTelemetryReader` after every successful `rtk gain` poll.
    public func recordCompressionSummary(_ summary: CompressionSummary) {
        snapshot.compressionSummary = summary
        persist()
    }

    /// Drop the compression summary entirely — used when RTK gets
    /// uninstalled (binary disappears from disk). UI then renders the
    /// metric card as "未启用 / —". No-op if already nil so we don't
    /// thrash the on-disk file every poll cycle when RTK is absent.
    public func clearCompressionSummary() {
        guard snapshot.compressionSummary != nil else { return }
        snapshot.compressionSummary = nil
        persist()
    }

    /// Calendar-day key in local time. Local — not UTC — because the
    /// user reads "today" against their wall clock.
    public static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func persist() {
        try? LLMProxySupportPaths.ensureDirectoryExists()
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        // `.atomic` writes to a `.tmp` sibling and renames — same atomic
        // semantic the spec asked for, just delegated to Foundation.
        try? data.write(to: url, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
