import Foundation

/// Three-port routing taxonomy. Every `UpstreamProfile` falls into
/// exactly one group; the LLM proxy listens on one port per group:
///
/// | Group            | Port  | Examples                          |
/// |------------------|-------|-----------------------------------|
/// | `officialClaude` | 9710  | builtin `anthropic-native` only   |
/// | `deepseek`       | 9711  | builtin `deepseek-v4-pro/flash`   |
/// | `thirdParty`     | 9712  | every custom profile, regardless  |
/// |                  |       | of baseURL host                   |
///
/// **Why each port owns a group rather than dynamic-routing one
/// port:** clean billing/quota attribution (the user wants 9710's
/// usage to roll up to their Anthropic OAuth subscription, 9711's
/// to a DeepSeek dollar balance, 9712's to per-profile third-party
/// accounts), clearer fault isolation (DeepSeek upstream slowness
/// can't poison the official-Claude listener's health monitor),
/// and trivial diagnosis from `lsof` / `netstat` — port number
/// already tells you the provider class.
///
/// **Builtin-only allowlist for `officialClaude`** is deliberate
/// (codex review pointed this out): if we inferred group from
/// `baseURL.host`, a custom profile pointing at
/// `api.anthropic.com` would silently land on 9710 and break the
/// port-per-group contract. The exception is locked to the
/// stable id `anthropic-native`. Custom profiles whose baseURL
/// happens to be Anthropic — typically a self-hosted Anthropic
/// reverse proxy — still go to `thirdParty`, which is correct
/// because the *endpoint owner* (and therefore the entity that
/// sees billing / blame for failures) is whoever runs that
/// proxy, not Anthropic itself.
public enum ProviderGroup: String, Sendable, Codable, CaseIterable {
    case officialClaude
    case deepseek
    case thirdParty
}

public extension ProviderGroup {
    /// Map a profile to the group whose listener should serve it.
    ///
    /// Decision tree (order matters):
    /// 1. The single builtin id `"anthropic-native"` → `officialClaude`.
    ///    No other id can land here, custom or otherwise.
    /// 2. Any builtin id starting with `"deepseek-"` (currently
    ///    `deepseek-v4-pro`, `deepseek-v4-flash`) → `deepseek`.
    ///    Custom profiles with `deepseek-*` ids do NOT match —
    ///    builtins-only here too, because a user could in
    ///    principle name a custom profile `deepseek-` something
    ///    pointing at any host. Those still go to `thirdParty`.
    /// 3. Everything else → `thirdParty`.
    static func infer(profile: UpstreamProfile) -> ProviderGroup {
        // Custom profiles always go to third-party regardless of
        // their id or baseURL — the user-visible group is
        // determined by ownership, not by what host they target.
        if profile.isCustom {
            return .thirdParty
        }
        if profile.id == "anthropic-native" {
            return .officialClaude
        }
        if profile.id.hasPrefix("deepseek-") {
            return .deepseek
        }
        // Defensive: any future builtin we haven't classified
        // here also lands in thirdParty rather than silently in
        // officialClaude, preserving the "9710 only blesses
        // anthropic-native" invariant.
        return .thirdParty
    }
}

public extension ProviderGroup {
    /// Default loopback port for this group. Mirrors what
    /// `LLMProxyCoordinator` will bind. Listed here (not on
    /// `LLMProxyConfiguration`) so that the shim layer
    /// (`oi-current-active-group`) can read it without taking
    /// a dependency on the proxy config struct.
    var defaultLoopbackPort: UInt16 {
        switch self {
        case .officialClaude: return 9710
        case .deepseek: return 9711
        case .thirdParty: return 9712
        }
    }

    /// Stable lowercase tag for log / diagnostic output. The
    /// coordinator prefixes log lines with `[<port> <tag>]`,
    /// e.g. `[9711 deepseek]`.
    var logTag: String { rawValue }
}
