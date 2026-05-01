import Foundation

// MARK: - Snapshot model

/// One client's worth of activity on one calendar day. The shape matches
/// what `IslandPanelView` and the LLM Spend control center pane consume.
public struct LLMDayBucket: Codable, Sendable, Equatable {
    public var turns: Int
    public var tokensIn: Int
    public var tokensOut: Int
    public var costUsd: Double
    /// Turns whose model wasn't in the pricing table. Tokens are still
    /// counted in tokensIn/tokensOut, but cost couldn't be computed.
    /// UI uses this to distinguish `$0.00` (genuinely cheap) from `—`
    /// (we don't know how to price this model — table needs updating).
    public var unpricedTurns: Int
    public var duplicateToolCalls: Int
    public var lastWarning: LLMDuplicateWarning?
    public var lastUpdatedAt: Date?

    public init(
        turns: Int = 0,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        costUsd: Double = 0,
        unpricedTurns: Int = 0,
        duplicateToolCalls: Int = 0,
        lastWarning: LLMDuplicateWarning? = nil,
        lastUpdatedAt: Date? = nil
    ) {
        self.turns = turns
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUsd = costUsd
        self.unpricedTurns = unpricedTurns
        self.duplicateToolCalls = duplicateToolCalls
        self.lastWarning = lastWarning
        self.lastUpdatedAt = lastUpdatedAt
    }

    enum CodingKeys: String, CodingKey {
        case turns, tokensIn, tokensOut, costUsd, unpricedTurns
        case duplicateToolCalls, lastWarning, lastUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        unpricedTurns = try c.decodeIfPresent(Int.self, forKey: .unpricedTurns) ?? 0
        duplicateToolCalls = try c.decodeIfPresent(Int.self, forKey: .duplicateToolCalls) ?? 0
        lastWarning = try c.decodeIfPresent(LLMDuplicateWarning.self, forKey: .lastWarning)
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
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

/// On-disk snapshot. `days` is keyed by `yyyy-MM-dd` (local time) →
/// client raw value → bucket. Bumping `version` is the migration hook.
public struct LLMStatsSnapshot: Codable, Sendable, Equatable {
    public var version: Int
    public var days: [String: [String: LLMDayBucket]]

    public init(version: Int = 1, days: [String: [String: LLMDayBucket]] = [:]) {
        self.version = version
        self.days = days
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
        usage: TokenUsage,
        costUsd: Double?
    ) {
        let key = Self.dayKey(for: date)
        var dayBuckets = snapshot.days[key] ?? [:]
        var bucket = dayBuckets[client.rawValue] ?? LLMDayBucket()
        bucket.turns += 1
        bucket.tokensIn += usage.input + usage.cacheWrite + usage.cacheRead
        bucket.tokensOut += usage.output
        if let costUsd {
            bucket.costUsd += costUsd
        } else {
            bucket.unpricedTurns += 1
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
