import Foundation

/// Static lookup of model id → maximum context window in tokens.
///
/// Used by `LLMUsageObserver` to compute "context fill %" — the
/// fraction of the model's window the current turn already occupies.
/// Returns `nil` for unknown models so the UI can render "—" rather
/// than a misleading percentage. Same nil-on-unknown discipline as
/// `LLMPricing.costUSD`.
///
/// **Adding a model**: append a row with the prefix + verified
/// context size, plus a comment naming the source URL and the
/// verification date. The lookup is longest-prefix, so a precise
/// dated suffix (e.g. `claude-opus-4-7-20251205`) will resolve via
/// the `claude-opus-4-7` row without an explicit dated entry.
public enum ModelContextLimits {
    private struct Entry {
        let prefix: String
        let contextTokens: Int
    }

    /// Sources + verification timestamps in inline comments. Bump and
    /// re-verify when bumping the table.
    private static let table: [Entry] = [
        // Anthropic — verified 2026-05-03 against
        // https://docs.anthropic.com/en/docs/about-claude/models
        //
        // Model ids may carry a `-1m` suffix or `[1m]` bracket
        // variant indicating Anthropic's extended 1M-context SKU
        // (e.g. `claude-opus-4-7[1m]` is the form Claude Code
        // emits). We list those as DISTINCT table entries; the
        // longest-prefix matcher picks them over the bare 200K row.
        // No proxy-side normalization happens — earlier comment
        // claimed `LLMProxyHTTP` strips `[1m]` but a grep finds no
        // such code path, so the lookup must handle the suffix on
        // its own. Future SKUs (e.g. `-2m` if released) require an
        // explicit row.
        Entry(prefix: "claude-opus-4-7[1m]", contextTokens: 1_000_000),
        Entry(prefix: "claude-opus-4-7-1m", contextTokens: 1_000_000),
        Entry(prefix: "claude-opus-4-7", contextTokens: 200_000),
        Entry(prefix: "claude-opus-4-6", contextTokens: 200_000),
        Entry(prefix: "claude-opus-4-5", contextTokens: 200_000),
        Entry(prefix: "claude-sonnet-4-6-1m", contextTokens: 1_000_000),
        Entry(prefix: "claude-sonnet-4-6", contextTokens: 200_000),
        // claude-sonnet-4-5-1m is Anthropic's first published 1M
        // beta SKU (Aug 2025 release). Listed even when not actively
        // selected by Open Island users today, because Claude Code
        // can still pin to it via env override and we don't want a
        // misclassification regression if anyone does.
        Entry(prefix: "claude-sonnet-4-5-1m", contextTokens: 1_000_000),
        Entry(prefix: "claude-sonnet-4-5", contextTokens: 200_000),
        Entry(prefix: "claude-haiku-4-5", contextTokens: 200_000),

        // OpenAI — DELIBERATELY OMITTED. As of 2026-05-02 the GPT-5
        // family fragmented into 5.2/5.3/5.4/5.4-mini/5.5 with
        // context windows ranging 128K → 1M+ and ChatGPT-vs-API
        // limits diverging within a single name. Lookup returns nil
        // for these and the UI renders "—". Add a row only when the
        // (model id → context window) pair is verifiable from the
        // upstream model docs, not inferred.
    ]

    /// Returns the maximum context window for the given model id, via
    /// longest-prefix match. `nil` if no entry covers the id — the
    /// caller must treat this as "unknown" rather than guessing.
    public static func maxContextTokens(forModel model: String) -> Int? {
        var bestPrefix: String?
        var bestLimit: Int?
        for entry in table where model.hasPrefix(entry.prefix) {
            if bestPrefix == nil || entry.prefix.count > bestPrefix!.count {
                bestPrefix = entry.prefix
                bestLimit = entry.contextTokens
            }
        }
        return bestLimit
    }
}
