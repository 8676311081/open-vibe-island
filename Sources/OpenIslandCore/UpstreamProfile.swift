import Foundation

/// Per-provider cost / capability metadata used by the routing UI
/// to render comparable model cards. Optional on `UpstreamProfile`
/// because Custom profiles created by the user may not have
/// reliable cost data.
public struct ProfileCostMetadata: Codable, Sendable, Equatable {
    /// USD per million input tokens (uncached fresh write).
    public let inputUSDPerMtok: Double
    /// USD per million output tokens.
    public let outputUSDPerMtok: Double
    /// USD per million cache_read tokens. `nil` when the provider
    /// does not support prompt caching at all (UI renders "no cache"
    /// rather than a misleading $0.00).
    public let cacheReadUSDPerMtok: Double?
    /// Maximum context window size in tokens, e.g. 200_000 for
    /// Anthropic Sonnet, 1_000_000 for DeepSeek V4. UI uses this to
    /// surface context-fill warnings relative to the right ceiling.
    public let contextWindowTokens: Int
    /// When the discounted pricing in this metadata expires. `nil`
    /// = no time-limited discount, prices are stable. The routing
    /// pane uses this to render a "discount expires in N days"
    /// chip during the last 30 days, after which the source-of-
    /// truth prices need a code update + new release.
    public let discountExpiresAt: Date?

    public init(
        inputUSDPerMtok: Double,
        outputUSDPerMtok: Double,
        cacheReadUSDPerMtok: Double? = nil,
        contextWindowTokens: Int,
        discountExpiresAt: Date? = nil
    ) {
        self.inputUSDPerMtok = inputUSDPerMtok
        self.outputUSDPerMtok = outputUSDPerMtok
        self.cacheReadUSDPerMtok = cacheReadUSDPerMtok
        self.contextWindowTokens = contextWindowTokens
        self.discountExpiresAt = discountExpiresAt
    }
}

/// One row of the routing table. Resolves an upstream URL to:
///   - which Keychain credential to use (`keychainAccount`)
///   - which body-`model` to substitute (`modelOverride`, RESERVED
///     for 4.x — DeepSeek V4 Pro / Flash share the same baseURL but
///     need different `model` values in the request body)
///   - what to render in the routing card (`displayName`,
///     `costMetadata`)
///
/// Three built-in profiles ship in `BuiltinProfiles.all`. Users can
/// add their own via `UpstreamProfileStore.addCustomProfile(_:)`,
/// stored as JSON in `UserDefaults` under
/// `OpenIsland.LLMProxy.customProfiles`.
public struct UpstreamProfile: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier. `anthropic-native`, `deepseek-v4-pro`,
    /// `deepseek-v4-flash` for builtins; user-defined string for
    /// custom profiles. Must be unique across all profiles in a
    /// store at any moment.
    public let id: String
    /// Localization key (not the rendered string). UI resolves this
    /// via `LanguageManager.t(_:)` at display time.
    public let displayName: String
    /// Upstream API base URL. The proxy forwards request paths
    /// concatenated onto this — so `https://api.deepseek.com/anthropic`
    /// + path `/v1/messages` lands at
    /// `https://api.deepseek.com/anthropic/v1/messages`. The proxy
    /// already supports custom base URLs via 254df19; this profile
    /// just selects which one is active.
    public let baseURL: URL
    /// `nil` for upstreams that consume the user's claude-CLI key
    /// directly (Anthropic native). Otherwise the Keychain account
    /// name to look up in `RouterCredentialsStore` for the
    /// Authorization header rewrite — e.g. "deepseek".
    public let keychainAccount: String?
    /// **RESERVED for 4.x.** Future body mutation will replace the
    /// request's `model` field with this when set, so a single
    /// upstream URL can host multiple models (DeepSeek V4 Pro vs
    /// Flash). 4.2 commits this field as data only — no rewriter
    /// behavior change yet.
    public let modelOverride: String?
    /// `false` for hardcoded built-ins, `true` for user-defined
    /// profiles. Drives UI affordances (only Custom profiles can
    /// be edited / removed).
    public let isCustom: Bool
    /// Optional pricing data. Built-ins have it; user-defined
    /// Custom profiles may omit (UI renders "?").
    public let costMetadata: ProfileCostMetadata?

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        keychainAccount: String? = nil,
        modelOverride: String? = nil,
        isCustom: Bool,
        costMetadata: ProfileCostMetadata? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
        self.modelOverride = modelOverride
        self.isCustom = isCustom
        self.costMetadata = costMetadata
    }
}

/// Errors returned from `UpstreamProfileStore` mutations.
public enum UpstreamProfileError: LocalizedError, Sendable, Equatable {
    case unknownProfile(id: String)
    case idCollidesWithBuiltin(id: String)
    case cannotAddBuiltinAsCustom
    case cannotRemoveBuiltin(id: String)

    public var errorDescription: String? {
        switch self {
        case let .unknownProfile(id):
            return "No upstream profile with id '\(id)'."
        case let .idCollidesWithBuiltin(id):
            return "Cannot add custom profile with id '\(id)' — collides with a built-in."
        case .cannotAddBuiltinAsCustom:
            return "Profiles passed to addCustomProfile must have isCustom = true."
        case let .cannotRemoveBuiltin(id):
            return "Built-in profile '\(id)' cannot be removed."
        }
    }
}
