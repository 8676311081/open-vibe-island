import Foundation

/// Per-model token pricing in USD per million tokens.
///
/// The four columns map directly to the token classes the providers
/// report:
///
///   * `inputPerMTok` — uncached prompt tokens
///   * `cacheWritePerMTok` — Anthropic `cache_creation_input_tokens`
///                           (≈ 1.25× input by Anthropic's pricing rule)
///   * `cacheReadPerMTok` — Anthropic `cache_read_input_tokens` /
///                           OpenAI `cached_tokens`
///                           (≈ 0.1× input by Anthropic's pricing rule)
///   * `outputPerMTok` — completion tokens
///
/// OpenAI doesn't have a separate cache-write rate; we set it equal to
/// the input rate so cost math is uniform across providers.
public struct ModelPricing: Sendable, Equatable, Codable {
    public let inputPerMTok: Double
    public let cacheWritePerMTok: Double
    public let cacheReadPerMTok: Double
    public let outputPerMTok: Double

    public init(
        inputPerMTok: Double,
        cacheWritePerMTok: Double,
        cacheReadPerMTok: Double,
        outputPerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.outputPerMTok = outputPerMTok
    }
}

public struct TokenUsage: Sendable, Equatable, Codable, Hashable {
    public var input: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int

    public init(
        input: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0
    ) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public static let zero = TokenUsage()

    public var totalTokens: Int {
        input + cacheWrite + cacheRead + output
    }
}

/// Pricing reference table and helpers. The table is the *only* thing
/// you need to update when prices change — everything else is data-driven.
public enum LLMPricing {
    /// Hardcoded reference rates (USD per million tokens). Refreshed
    /// 2026-05-01. Models below are matched via longest-prefix so
    /// date-suffixed IDs (e.g. `claude-sonnet-4-5-20250929`) resolve
    /// correctly without explicit aliasing.
    public static let table: [String: ModelPricing] = [
        // Anthropic
        "claude-sonnet-4-5": ModelPricing(
            inputPerMTok: 3.00,
            cacheWritePerMTok: 3.75,
            cacheReadPerMTok: 0.30,
            outputPerMTok: 15.00
        ),
        "claude-sonnet-4-6": ModelPricing(
            inputPerMTok: 3.00,
            cacheWritePerMTok: 3.75,
            cacheReadPerMTok: 0.30,
            outputPerMTok: 15.00
        ),
        // Opus 4.x has been at $5/$25 since Opus 4.5's 67% cut — not
        // the historical $15/$75 of Opus 3. Same rate carries through
        // 4.6 and 4.7.
        "claude-opus-4-6": ModelPricing(
            inputPerMTok: 5.00,
            cacheWritePerMTok: 6.25,
            cacheReadPerMTok: 0.50,
            outputPerMTok: 25.00
        ),
        "claude-opus-4-7": ModelPricing(
            inputPerMTok: 5.00,
            cacheWritePerMTok: 6.25,
            cacheReadPerMTok: 0.50,
            outputPerMTok: 25.00
        ),
        "claude-haiku-4-5": ModelPricing(
            inputPerMTok: 1.00,
            cacheWritePerMTok: 1.25,
            cacheReadPerMTok: 0.10,
            outputPerMTok: 5.00
        ),
        // OpenAI — cacheWrite equals input since OpenAI has no separate
        // cache-creation premium.
        "gpt-5": ModelPricing(
            inputPerMTok: 1.25,
            cacheWritePerMTok: 1.25,
            cacheReadPerMTok: 0.125,
            outputPerMTok: 10.00
        ),
        "gpt-4o": ModelPricing(
            inputPerMTok: 2.50,
            cacheWritePerMTok: 2.50,
            cacheReadPerMTok: 1.25,
            outputPerMTok: 10.00
        ),
        "gpt-4o-mini": ModelPricing(
            inputPerMTok: 0.15,
            cacheWritePerMTok: 0.15,
            cacheReadPerMTok: 0.075,
            outputPerMTok: 0.60
        ),
    ]

    public static func priceFor(model: String?) -> ModelPricing? {
        guard let model, !model.isEmpty else { return nil }
        if let exact = table[model] { return exact }
        // Longest-prefix match so `claude-sonnet-4-5-20250929` resolves to
        // the `claude-sonnet-4-5` row instead of `claude-sonnet-4` (which
        // doesn't exist in the table — but the principle holds for any
        // future short/long pairs).
        let sortedKeys = table.keys.sorted { $0.count > $1.count }
        for key in sortedKeys where model.hasPrefix(key) {
            return table[key]
        }
        return nil
    }

    /// Returns nil for models not in the pricing table — caller must
    /// distinguish "we have no price" (display `—`, increment
    /// `unpricedTurns`) from "the math came out to zero" (display
    /// `$0.00`). Silent zero would hide drift between the table and
    /// real provider pricing.
    public static func costUSD(model: String?, usage: TokenUsage) -> Double? {
        guard let p = priceFor(model: model) else { return nil }
        let scale = 1_000_000.0
        return Double(usage.input) * p.inputPerMTok / scale
            + Double(usage.cacheWrite) * p.cacheWritePerMTok / scale
            + Double(usage.cacheRead) * p.cacheReadPerMTok / scale
            + Double(usage.output) * p.outputPerMTok / scale
    }
}
