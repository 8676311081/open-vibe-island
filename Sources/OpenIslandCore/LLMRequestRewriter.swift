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
/// 4. **Rewrite request body `model` field for non-Anthropic
///    profiles** — when the active `UpstreamProfile` carries a
///    `modelOverride` string (DeepSeek V4 Pro/Flash both target
///    `api.deepseek.com/anthropic` and accept ONLY their own model
///    ids), substitute `modelOverride` in for whatever model the
///    client put on the request body. claude CLI sends Anthropic
///    ids like `claude-opus-4-7[1m]`; without this rewrite the
///    DeepSeek upstream returns 400/422 for "unknown model". Lives
///    in `rewriteModelFieldIfNeeded`. Profiles with `modelOverride
///    == nil` (anthropic-native) are left untouched. Path-gated to
///    `/v1/messages` and `/v1/chat/completions` so
///    `/v1/models`-style admin probes pass through.
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
        guard let profile = profileResolver.profileMatching(url: upstreamURL) else {
            return
        }
        rewriteAuthorizationIfNeeded(
            &headers,
            profile: profile,
            credentialsStore: credentialsStore
        )
    }

    /// Direct-profile variant. Used by the proxy hot path after T2's
    /// per-request resolution: the proxy resolves once at request
    /// entry and passes the resolved `UpstreamProfile` here, so the
    /// rewriter never re-reads active state and a mid-flight profile
    /// switch cannot tear the request between resolution and forward.
    ///
    /// Behavior is identical to the URL-lookup variant once a profile
    /// is in hand: profiles with `keychainAccount == nil`
    /// (Anthropic Native passthrough) no-op; profiles with a stored
    /// key that resolves to a non-empty value replace any existing
    /// `Authorization` header.
    public static func rewriteAuthorizationIfNeeded(
        _ headers: inout [(name: String, value: String)],
        profile: UpstreamProfile,
        credentialsStore: RouterCredentialsStore
    ) {
        guard let account = profile.keychainAccount else {
            // Pass-through profile (Anthropic Native uses claude CLI's
            // own key).
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

    /// Path-gate for the body model rewrite. We only mutate bodies
    /// the upstream actually parses as request bodies with a `model`
    /// field. Other endpoints (e.g. `/v1/models`, `/v1/health`) pass
    /// through untouched even if active profile has a modelOverride.
    public static func shouldRewriteModelField(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("/v1/messages") || lower.hasPrefix("/v1/chat/completions")
    }

    /// Substitute the active profile's `modelOverride` into the
    /// request body's top-level `model` field. Returns the rewritten
    /// body data, or the original body if no rewrite is required /
    /// possible.
    ///
    /// **No-op cases** (caller's body passes through unchanged):
    /// - `profileResolver` is nil (legacy callers without routing)
    /// - active profile has `modelOverride == nil` (anthropic-native)
    /// - body is empty or not valid JSON
    /// - top-level JSON value isn't an object (degenerate request —
    ///   we don't synthesize fields, just rewrite existing ones)
    /// - object has no `model` field — fail-closed: don't INVENT a
    ///   field the client didn't send. The upstream will surface
    ///   the missing-model error directly, which is louder than us
    ///   silently injecting a value.
    ///
    /// Bracketed / dated suffix variants like
    /// `claude-opus-4-7[1m]` and `claude-opus-4-7-20251205` are
    /// replaced wholesale — the entire `model` value becomes the
    /// override regardless of input shape.
    public static func rewriteModelFieldIfNeeded(
        _ body: Data,
        path: String,
        profileResolver: any UpstreamProfileResolver
    ) -> Data {
        rewriteModelFieldIfNeeded(
            body,
            path: path,
            profile: profileResolver.currentActiveProfile()
        )
    }

    /// Direct-profile variant. Same contract as the resolver-based
    /// overload, but takes the resolved `UpstreamProfile` directly so
    /// the proxy hot path can resolve once at request entry and pass
    /// the result through without race risk.
    public static func rewriteModelFieldIfNeeded(
        _ body: Data,
        path: String,
        profile: UpstreamProfile
    ) -> Data {
        guard shouldRewriteModelField(path: path) else { return body }
        guard let override = profile.modelOverride, !override.isEmpty else {
            return body
        }
        guard !body.isEmpty,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return body }
        guard json["model"] != nil else {
            // Fail-closed: don't fabricate a model field. Upstream
            // 400 with a clear error is better than us guessing.
            return body
        }
        json["model"] = override
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return rewritten
    }
}
