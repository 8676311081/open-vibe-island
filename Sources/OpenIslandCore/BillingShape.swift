import Foundation

/// How a routing profile gets billed. The spend UI's three-card
/// layout (one card per provider group) renders columns differently
/// for each shape — Claude Max/Pro shows a 5h-window progress bar,
/// DeepSeek shows a USD balance, BuerAI shows a quota / expiry,
/// generic third-party falls back to raw token counts.
///
/// Codex's review pointed out that trying to unify everything as
/// "USD spent today" is the wrong abstraction: a Claude Max user
/// doesn't pay per-token, a BuerAI subscriber's bill doesn't tick
/// down on usage, and a custom profile with no pricing table
/// genuinely cannot be priced. Different shapes, different columns.
public enum BillingShape: Equatable, Sendable {
    /// Time-windowed subscription quota — Anthropic Max/Pro is the
    /// canonical example: a 5-hour rolling window resets on its own
    /// schedule, no per-token billing. UI shows
    /// `<used>% used, resets in <duration>` plus the underlying
    /// token totals (read-only — there's no balance to draw down).
    case subscriptionWindow

    /// USD balance ticked down by the upstream per request. The
    /// provider exposes a `/user/balance`-style endpoint we can
    /// poll to surface "available USD" and / or "spent today USD".
    /// DeepSeek official, OpenRouter, OpenAI all fit. UI shows
    /// `$<spent today> · $<remaining>`.
    case meteredCredits

    /// Pre-paid included quota that doesn't deduct USD — the user
    /// bought a "100M token" or "unlimited" package with an
    /// expiration date. BuerAI is the prototype. UI shows
    /// `<used> / <total> · expires <date>` with no USD.
    case includedQuota

    /// We can count tokens but have no pricing or quota signal.
    /// Self-hosted vLLM, an ad-hoc reverse proxy, any custom
    /// profile we don't recognize. UI shows raw token counts and
    /// explicitly skips USD estimation rather than making one up.
    case tokenOnly

    /// We can't even reliably count tokens (no pricing, no balance,
    /// upstream's response shape unknown). Defensive — should be
    /// rare in practice. UI shows the profile id and a "billing
    /// data unavailable" line.
    case unknown
}

/// Hosts that the spend UI knows how to price + balance-query.
/// Kept narrow on purpose: every entry costs us a vendor-specific
/// integration (balance endpoint, pricing table, freshness window).
/// Future: move into a UserDefaults-backed table so users can
/// register their own "this is my OpenAI-compatible OpenRouter
/// fork" without code changes.
public enum BillingHostRegistry {
    /// OpenRouter's well-known host. They expose `/api/v1/credits`
    /// for balance and per-model price metadata.
    static let openRouterHosts: Set<String> = [
        "openrouter.ai",
    ]
    /// DeepSeek's primary host. `/user/balance` is the documented
    /// endpoint (codex pointed this out — not `/dashboard/billing/`,
    /// which we previously got wrong).
    static let deepseekHosts: Set<String> = [
        "api.deepseek.com",
    ]
    /// BuerAI's known host. They sell included-quota subscriptions;
    /// we surface "expires in N days" rather than USD spent.
    static let buerAIHosts: Set<String> = [
        "api.buerai.top",
        "buerai.top",
    ]
}

public extension BillingShape {
    /// Infer the shape for a routing profile. Decision rules in
    /// priority order:
    ///
    /// 1. Builtin `anthropic-native` → `subscriptionWindow`. Only
    ///    the canonical Anthropic OAuth path; a custom profile
    ///    pointing at api.anthropic.com (e.g. self-hosted reverse
    ///    proxy) does NOT count — its billing belongs to whoever
    ///    runs the proxy.
    /// 2. Builtin `deepseek-*` → `meteredCredits`. The
    ///    `/user/balance` poller knows how to talk to DeepSeek.
    /// 3. Custom profile with a known billing host (openrouter.ai
    ///    / buerai.top / api.deepseek.com) → matched shape.
    /// 4. Custom profile with any other host → `tokenOnly`. We
    ///    have no balance endpoint and no pricing table; the UI
    ///    will show raw counts.
    /// 5. Defensively, anything else → `unknown`.
    static func infer(profile: UpstreamProfile) -> BillingShape {
        // Builtins are special-cased by id, not by host. A custom
        // profile cloning the builtin id is impossible (the store
        // rejects collisions), so this is unambiguous.
        if !profile.isCustom {
            if profile.id == "anthropic-native" {
                return .subscriptionWindow
            }
            if profile.id.hasPrefix("deepseek-") {
                return .meteredCredits
            }
            return .unknown
        }
        // Custom profiles: route by host. Lowercased + stripped of
        // any port suffix to match the registry's bare-host keys.
        let host = profile.baseURL.host?.lowercased() ?? ""
        if BillingHostRegistry.deepseekHosts.contains(host) {
            return .meteredCredits
        }
        if BillingHostRegistry.openRouterHosts.contains(host) {
            return .meteredCredits
        }
        if BillingHostRegistry.buerAIHosts.contains(host) {
            return .includedQuota
        }
        // Unknown host on a custom profile — count tokens, no $.
        return .tokenOnly
    }
}

public extension BillingShape {
    /// One-line label for diagnostic / accessibility output. The
    /// real UI uses localized strings, but this lets `os_log` lines
    /// and unit tests pretty-print the shape without pulling in
    /// the lang manager.
    var diagnosticLabel: String {
        switch self {
        case .subscriptionWindow: return "subscription-window"
        case .meteredCredits: return "metered-credits"
        case .includedQuota: return "included-quota"
        case .tokenOnly: return "token-only"
        case .unknown: return "unknown"
        }
    }

    /// `true` when we can plausibly render a USD figure for this
    /// shape — UI uses this to decide whether to show a `$X.XX`
    /// column at all (vs. hiding it to avoid implying a spend
    /// that doesn't exist).
    var displaysUSD: Bool {
        switch self {
        case .meteredCredits, .tokenOnly:
            // tokenOnly USD is best-effort estimate IF a pricing
            // metadata is attached to the profile; the UI decides
            // per-row whether to actually render it.
            return true
        case .subscriptionWindow, .includedQuota, .unknown:
            return false
        }
    }
}
