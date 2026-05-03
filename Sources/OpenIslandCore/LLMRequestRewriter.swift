import Foundation

/// Audited mutations the proxy is allowed to make to an in-flight
/// request. The proxy is otherwise an opaque forwarder — anything
/// not listed below MUST pass through bit-for-bit. New entries
/// require an explicit commit + audit-trail update.
///
/// 1. **Strip incoming `Accept-Encoding` and force `identity`** —
///    URLSession transparently gunzips response bodies but leaves
///    `Content-Encoding: gzip` in the headers, breaking any
///    downstream client that respects the header. Forcing identity
///    upstream guarantees what URLSession hands us is what upstream
///    sent. Lives at the call site in `LLMProxyServer` (header
///    forwarding loop) rather than this file because it doesn't
///    need any context — just an unconditional override per request.
///
/// 2. **Inject `stream_options.include_usage = true` on OpenAI
///    streaming `/v1/chat/completions`** — chat/completions omits
///    the final `usage` block unless this opt-in is set. Without
///    it our token stats lose every chat/completions stream that
///    a non-Codex client opens. Bit-for-bit identical otherwise; a
///    client that explicitly set `include_usage: false` is
///    respected. See `rewrittenChatCompletionsBody`.
///
/// 3. **Rewrite `Authorization` header for non-Anthropic upstreams
///    that speak Anthropic format** — when user has pointed
///    `anthropicUpstream` at e.g. `api.deepseek.com/anthropic`, the
///    Bearer token claude CLI sends is the user's Anthropic key,
///    not the DeepSeek key. We replace it with the Keychain-stored
///    credential for the matched provider so the request reaches
///    the right backend with the right credential. Fail-open: if
///    the upstream looks non-Anthropic but we have no stored key
///    for that provider, do NOT replace — let the upstream return
///    401 so the misconfiguration is loud. See
///    `rewriteAuthorizationIfNeeded`.
///
/// 4. **(RESERVED for 4.x)** Rewrite request body `model` field
///    when active profile is a DeepSeek V4 Pro/Flash variant
///    sharing the same endpoint. Stub-only in this commit.
///
/// **What we do not touch:** message content, tool definitions,
/// temperature, system prompts, model selection (outside item #4),
/// any non-listed header. Observability that distorts traffic is
/// worse than no observability at all.
public enum LLMRequestRewriter {
    /// Path-based gate. Only chat/completions needs the body
    /// rewrite — Anthropic `/v1/messages` and OpenAI `/v1/responses`
    /// emit usage unconditionally.
    public static func shouldRewrite(path: String) -> Bool {
        path.lowercased().hasPrefix("/v1/chat/completions")
    }

    public static func rewrittenChatCompletionsBody(_ body: Data) -> Data {
        guard !body.isEmpty,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return body }
        guard let stream = json["stream"] as? Bool, stream == true else {
            return body
        }
        var streamOptions = json["stream_options"] as? [String: Any] ?? [:]
        if streamOptions["include_usage"] != nil {
            // Client made an explicit choice — respect it, even if false.
            return body
        }
        streamOptions["include_usage"] = true
        json["stream_options"] = streamOptions
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return rewritten
    }

    /// Mutate `headers` in place: when the upstream URL matches a
    /// known non-Anthropic provider AND the corresponding credential
    /// is in `credentialsStore`, replace any `Authorization` header
    /// (case-insensitive name match) with `Bearer <stored-key>`. If
    /// no header exists, append one. Multiple existing case-variant
    /// `Authorization` headers collapse to a single override.
    ///
    /// **No-op cases** (caller-side header passes through unchanged):
    /// - Upstream host is Anthropic (or anything not in the
    ///   provider table)
    /// - Upstream matches a known provider but no key is stored —
    ///   fail-open, so the upstream's 401 surfaces the
    ///   misconfiguration instead of us silently sending an empty
    ///   token
    /// - Upstream URL has no host (degenerate / file URL)
    ///
    /// Provider matching is delegated to `profileResolver` —
    /// `UpstreamProfileStore` ships built-in profiles for Anthropic
    /// Native + DeepSeek V4 Pro/Flash and lets users add Custom
    /// profiles. The rewriter does NOT know about specific hosts;
    /// it only asks "does this URL map to a profile that wants a
    /// stored credential?".
    public static func rewriteAuthorizationIfNeeded(
        _ headers: inout [(name: String, value: String)],
        upstreamURL: URL,
        profileResolver: any UpstreamProfileResolver,
        credentialsStore: RouterCredentialsStore
    ) {
        guard let profile = profileResolver.profileMatching(url: upstreamURL),
              let account = profile.keychainAccount
        else {
            // No matching profile, OR a matching profile that wants
            // pass-through (Anthropic Native uses claude CLI's own
            // key — `keychainAccount = nil`).
            return
        }
        // `try?` flattens `throws -> String?` to `String?` (SE-0230),
        // so a thrown Keychain error and a missing-key both surface
        // as nil here. Both should fail-open: surfacing as a request
        // failure would be worse UX than letting upstream 401 expose
        // the misconfiguration.
        guard let key = try? credentialsStore.credential(for: account), !key.isEmpty else {
            return
        }
        let newValue = "Bearer \(key)"
        if let firstIdx = headers.firstIndex(where: { $0.name.lowercased() == "authorization" }) {
            headers[firstIdx] = (name: headers[firstIdx].name, value: newValue)
            // Strip any further duplicate Authorization headers (HTTP
            // allows multi-value headers, but Authorization is
            // conventionally single — sending two would confuse the
            // upstream). Iterate from the right so removals don't
            // shift indices we still need.
            var i = headers.count - 1
            while i > firstIdx {
                if headers[i].name.lowercased() == "authorization" {
                    headers.remove(at: i)
                }
                i -= 1
            }
        } else {
            headers.append((name: "Authorization", value: newValue))
        }
    }
}
