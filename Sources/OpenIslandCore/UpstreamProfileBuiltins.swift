import Foundation

/// Hardcoded `UpstreamProfile`s that ship with Open Island. Updated
/// whenever a provider changes pricing / endpoint / context window;
/// users add their own via `UpstreamProfileStore.addCustomProfile`.
///
/// Pricing is per million tokens, USD. Numbers are sourced from the
/// providers' public pricing pages on the date noted next to each
/// entry — when discount windows expire (DeepSeek's 75%-off is
/// scheduled to lapse 2026-05-31), the next release ships with
/// updated `inputUSDPerMtok` / `outputUSDPerMtok` and
/// `discountExpiresAt: nil`.
public enum BuiltinProfiles {
    /// 2026-05-31 23:59:59 UTC. Computed once at module load.
    /// DeepSeek's "75% off" promo on V4 Pro/Flash expires at this
    /// instant; UI surfaces a "discount expires in N days" chip
    /// during the last 30 days, then the next release bumps prices.
    public static let deepseekV4DiscountExpiresAt: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 31
        components.hour = 23
        components.minute = 59
        components.second = 59
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? Date.distantFuture
    }()

    public static let anthropicNative = UpstreamProfile(
        id: "anthropic-native",
        displayName: "modelRouting.profile.anthropic.native",
        baseURL: URL(string: "https://api.anthropic.com")!,
        keychainAccount: nil, // claude CLI's own key passes through
        modelOverride: nil,
        isCustom: false,
        costMetadata: ProfileCostMetadata(
            inputUSDPerMtok: 5.00,
            outputUSDPerMtok: 25.00,
            cacheReadUSDPerMtok: 0.50,
            contextWindowTokens: 200_000,
            discountExpiresAt: nil
        )
    )

    /// DeepSeek V4 Pro at the Anthropic-format endpoint
    /// (api.deepseek.com/anthropic). Discounted pricing through
    /// 2026-05-31 — full price is $1.74/$3.48.
    public static let deepseekV4Pro = UpstreamProfile(
        id: "deepseek-v4-pro",
        displayName: "modelRouting.profile.deepseek.v4Pro",
        baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
        keychainAccount: "deepseek",
        modelOverride: "deepseek-v4-pro", // applied by 4.x body rewriter
        isCustom: false,
        costMetadata: ProfileCostMetadata(
            inputUSDPerMtok: 0.435,
            outputUSDPerMtok: 0.87,
            cacheReadUSDPerMtok: 0.003625,
            contextWindowTokens: 1_000_000,
            discountExpiresAt: deepseekV4DiscountExpiresAt,
            listInputUSDPerMtok: 1.74,    // 75%-off discount removed
            listOutputUSDPerMtok: 3.48
        )
    )

    /// DeepSeek V4 Flash. Same upstream as V4 Pro — distinguished
    /// only by the body-level `model` field (handled in 4.x).
    public static let deepseekV4Flash = UpstreamProfile(
        id: "deepseek-v4-flash",
        displayName: "modelRouting.profile.deepseek.v4Flash",
        baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
        keychainAccount: "deepseek",
        modelOverride: "deepseek-v4-flash",
        isCustom: false,
        costMetadata: ProfileCostMetadata(
            inputUSDPerMtok: 0.14,
            outputUSDPerMtok: 0.28,
            cacheReadUSDPerMtok: 0.0028,
            contextWindowTokens: 1_000_000,
            discountExpiresAt: deepseekV4DiscountExpiresAt,
            listInputUSDPerMtok: 0.56,    // 75%-off discount removed
            listOutputUSDPerMtok: 1.12
        )
    )

    /// Order matters for UI rendering and the default-active fallback
    /// (`anthropicNative` is at index 0 → if the active id ever
    /// dangles, we route to safe Anthropic rather than DeepSeek with
    /// no key).
    public static let all: [UpstreamProfile] = [
        anthropicNative,
        deepseekV4Pro,
        deepseekV4Flash,
    ]

    /// Convenience accessor used by the routing pane / pill / store
    /// fallbacks. Always returns a built-in even if the active id
    /// references an unknown profile.
    public static func byID(_ id: String) -> UpstreamProfile? {
        all.first { $0.id == id }
    }
}
