import Foundation

/// Per-provider cost / capability metadata used by the routing UI
/// to render comparable model cards. Optional on `UpstreamProfile`
/// because Custom profiles created by the user may not have
/// reliable cost data.
public struct ProfileCostMetadata: Codable, Sendable, Equatable {
    /// USD per million input tokens (uncached fresh write). When
    /// `discountExpiresAt` is set, this is the discounted price
    /// shown today; the post-expiry "list" price lives in
    /// `listInputUSDPerMtok` so the UI can surface "discount
    /// expires in N days, list price will be $X" without a code
    /// update at expiry time.
    public let inputUSDPerMtok: Double
    /// USD per million output tokens. See `inputUSDPerMtok` for
    /// discount semantics.
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
    /// Post-expiry list price for input tokens (USD/Mtok). 0 = no
    /// list price specified (e.g. providers without time-limited
    /// discounts; their `inputUSDPerMtok` is already the list).
    /// Decoded with `?? 0` for backward compat with profiles
    /// serialized before this field was added.
    public let listInputUSDPerMtok: Double
    /// Post-expiry list price for output tokens. Same semantics as
    /// `listInputUSDPerMtok`.
    public let listOutputUSDPerMtok: Double

    public init(
        inputUSDPerMtok: Double,
        outputUSDPerMtok: Double,
        cacheReadUSDPerMtok: Double? = nil,
        contextWindowTokens: Int,
        discountExpiresAt: Date? = nil,
        listInputUSDPerMtok: Double = 0,
        listOutputUSDPerMtok: Double = 0
    ) {
        self.inputUSDPerMtok = inputUSDPerMtok
        self.outputUSDPerMtok = outputUSDPerMtok
        self.cacheReadUSDPerMtok = cacheReadUSDPerMtok
        self.contextWindowTokens = contextWindowTokens
        self.discountExpiresAt = discountExpiresAt
        self.listInputUSDPerMtok = listInputUSDPerMtok
        self.listOutputUSDPerMtok = listOutputUSDPerMtok
    }

    private enum CodingKeys: String, CodingKey {
        case inputUSDPerMtok, outputUSDPerMtok, cacheReadUSDPerMtok
        case contextWindowTokens, discountExpiresAt
        case listInputUSDPerMtok, listOutputUSDPerMtok
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputUSDPerMtok = try c.decode(Double.self, forKey: .inputUSDPerMtok)
        self.outputUSDPerMtok = try c.decode(Double.self, forKey: .outputUSDPerMtok)
        self.cacheReadUSDPerMtok = try c.decodeIfPresent(Double.self, forKey: .cacheReadUSDPerMtok)
        self.contextWindowTokens = try c.decode(Int.self, forKey: .contextWindowTokens)
        self.discountExpiresAt = try c.decodeIfPresent(Date.self, forKey: .discountExpiresAt)
        // Backward compat: pre-4.3 serialized profiles lack these
        // fields. `?? 0` keeps the existing custom profiles in
        // UserDefaults loadable.
        self.listInputUSDPerMtok = try c.decodeIfPresent(Double.self, forKey: .listInputUSDPerMtok) ?? 0
        self.listOutputUSDPerMtok = try c.decodeIfPresent(Double.self, forKey: .listOutputUSDPerMtok) ?? 0
    }

    // MARK: - Cost computation

    /// Effective input rate (USD/Mtok), accounting for discount expiry.
    /// When the discount window has closed AND a list price was
    /// supplied, returns the list price; otherwise returns the
    /// nominal `inputUSDPerMtok`.
    public func effectiveInputPrice(now: Date = Date()) -> Double {
        if let expiresAt = discountExpiresAt, expiresAt <= now,
           listInputUSDPerMtok > 0 {
            return listInputUSDPerMtok
        }
        return inputUSDPerMtok
    }

    /// Effective output rate — same discount-gate as
    /// `effectiveInputPrice`.
    public func effectiveOutputPrice(now: Date = Date()) -> Double {
        if let expiresAt = discountExpiresAt, expiresAt <= now,
           listOutputUSDPerMtok > 0 {
            return listOutputUSDPerMtok
        }
        return outputUSDPerMtok
    }

    /// Compute USD cost for a turn against this profile's pricing.
    /// Token units are raw counts; this method divides by 1e6
    /// internally. Callers pass `inputTokens` = request-tokens +
    /// cache-write tokens (billed at input rate) and `cacheReadTokens`
    /// = cache-read tokens (billed at the cache-read rate, falling
    /// back to 0 when the provider doesn't support cache — same
    /// nil→0 policy as the rest of the pricing pipeline).
    public func costUSD(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        now: Date = Date()
    ) -> Double {
        let scale = 1_000_000.0
        let inputPrice = effectiveInputPrice(now: now)
        let outputPrice = effectiveOutputPrice(now: now)
        let cacheReadPrice = cacheReadUSDPerMtok ?? 0
        return Double(inputTokens) * inputPrice / scale
            + Double(outputTokens) * outputPrice / scale
            + Double(cacheReadTokens) * cacheReadPrice / scale
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

// MARK: - Compact-pill helpers

extension UpstreamProfile {
    /// 3–6 character abbreviation rendered on the island pill chip.
    /// Hint, not source of truth — Anthropic Native stays "ANT"
    /// rather than reflecting Claude CLI's internal `/model`
    /// selection (Opus / Sonnet / Haiku) because the proxy can't
    /// reliably observe that without parsing every request body,
    /// and even if we did the chip is a glance-cue, not the
    /// authoritative provider state. Built-ins are switch-cased;
    /// custom profiles render the literal "CUSTOM" string regardless
    /// of their id, so users see a consistent affordance to "click
    /// → see which custom profile is active".
    public var compactPillAbbreviation: String {
        switch id {
        case "anthropic-native": return "ANT"
        case "deepseek-v4-pro": return "DSV4P"
        case "deepseek-v4-flash": return "DSV4F"
        default: return isCustom ? "CUSTOM" : id.uppercased()
        }
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
