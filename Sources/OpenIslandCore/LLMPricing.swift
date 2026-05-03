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
        // Match a row only when the model id is the key followed by a
        // dash separator — `claude-sonnet-4-5` resolves
        // `claude-sonnet-4-5-20250929` (date suffix) but does NOT
        // resolve `gpt-5.5` against `gpt-5`. Bare `hasPrefix` would
        // silently mis-price new model variants; this surfaces them
        // as unpriced so the table gets updated.
        let sortedKeys = table.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            let separator = key + "-"
            if model.hasPrefix(separator) {
                return table[key]
            }
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
        return computeCost(p, usage: usage)
    }

    /// Resolver-aware overload. Checks the static table first; on
    /// miss, looks up the active `UpstreamProfile` for a matching
    /// `modelOverride` and uses its `ProfileCostMetadata` for pricing.
    /// This bridges the gap between the static Anthropic/OpenAI rows
    /// and the profile-driven DeepSeek / future-provider rows —
    /// without duplicating the discount-expiry logic in this file.
    ///
    /// Profile cost metadata is the single source of truth for all
    /// non-static-table providers. When a profile goes through a
    /// discount window (e.g. DeepSeek V4 75% off → list price after
    /// 2026-05-31), the metadata's `effectiveInputPrice` gate handles
    /// the switchover automatically — no code update needed.
    public static func costUSD(
        model: String?,
        usage: TokenUsage,
        profileResolver: (any UpstreamProfileResolver)?
    ) -> Double? {
        if let p = priceFor(model: model) {
            return computeCost(p, usage: usage)
        }
        guard let resolver = profileResolver, let model, !model.isEmpty else {
            return nil
        }
        // Reverse-lookup: find a profile whose modelOverride equals
        // the model id the body rewriter substituted. This is a two-
        // entry walk for the current built-in set (anthropic-native
        // has nil modelOverride, so the only hits are DSV4P/Flash).
        let active = resolver.currentActiveProfile()
        guard active.modelOverride == model || active.id == model,
              let meta = active.costMetadata else {
            return nil
        }
        return meta.costUSD(
            inputTokens: usage.input + usage.cacheWrite,
            outputTokens: usage.output,
            cacheReadTokens: usage.cacheRead,
            now: Date()
        )
    }

    private static func computeCost(_ p: ModelPricing, usage: TokenUsage) -> Double {
        let scale = 1_000_000.0
        return Double(usage.input) * p.inputPerMTok / scale
            + Double(usage.cacheWrite) * p.cacheWritePerMTok / scale
            + Double(usage.cacheRead) * p.cacheReadPerMTok / scale
            + Double(usage.output) * p.outputPerMTok / scale
    }
}
