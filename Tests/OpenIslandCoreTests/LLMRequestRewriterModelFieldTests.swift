import Foundation
import Testing
@testable import OpenIslandCore

/// Tests for Phase 4.6.2: `LLMRequestRewriter.rewriteModelFieldIfNeeded`.
/// Item #4 of the rewriter audit list — substitutes the active
/// `UpstreamProfile.modelOverride` into the request body's `model`
/// field so non-Anthropic providers sharing the Anthropic-format
/// endpoint (DeepSeek `/anthropic`) don't reject claude CLI's
/// Anthropic model ids.
@Suite(.serialized)
struct LLMRequestRewriterModelFieldTests {
    /// Stub resolver — returns whatever profile we hand it. Avoids
    /// pulling in `UpstreamProfileStore` + UserDefaults plumbing for
    /// the unit-level tests; the routing-side tests in
    /// `LLMProxyActiveProfileRoutingTests` already exercise the real
    /// store.
    private struct StubResolver: UpstreamProfileResolver, Sendable {
        let active: UpstreamProfile
        func currentActiveProfile() -> UpstreamProfile { active }
        func profileMatching(url: URL) -> UpstreamProfile? { nil }
    }

    private static func makeResolver(active: UpstreamProfile) -> some UpstreamProfileResolver {
        StubResolver(active: active)
    }

    private static let bodyAnthropicOpus: Data = Data(
        #"{"model":"claude-opus-4-7","max_tokens":1,"messages":[]}"#.utf8
    )

    private static func decodedModel(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }

    @Test
    func bodyModelRewrittenWhenProfileHasOverride() {
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            Self.bodyAnthropicOpus,
            path: "/v1/messages",
            profileResolver: resolver
        )
        #expect(Self.decodedModel(rewritten) == "deepseek-v4-pro")
    }

    @Test
    func bodyModelUntouchedWhenProfileHasNilOverride() {
        // anthropic-native carries modelOverride = nil; the body must
        // pass through bit-identical (so byte equality is the
        // strictest assertion).
        let resolver = Self.makeResolver(active: BuiltinProfiles.anthropicNative)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            Self.bodyAnthropicOpus,
            path: "/v1/messages",
            profileResolver: resolver
        )
        #expect(rewritten == Self.bodyAnthropicOpus)
    }

    @Test
    func bodyModelRewriteHandlesDateSuffixedAnthropicIDs() {
        // claude CLI sometimes pins a dated checkpoint suffix; the
        // override replaces the entire model value, so dated input
        // still becomes a clean DeepSeek id.
        let body = Data(
            #"{"model":"claude-opus-4-7-20251205","messages":[]}"#.utf8
        )
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            body,
            path: "/v1/messages",
            profileResolver: resolver
        )
        #expect(Self.decodedModel(rewritten) == "deepseek-v4-pro")
    }

    @Test
    func bodyModelRewriteWithBracketSuffix() {
        // Claude CLI's actual on-the-wire model id for the 1M Opus
        // SKU is `claude-opus-4-7[1m]`. Bracketed form must rewrite
        // identically to the bare form — we don't normalize, we
        // overwrite.
        let body = Data(
            #"{"model":"claude-opus-4-7[1m]","messages":[]}"#.utf8
        )
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Flash)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            body,
            path: "/v1/messages",
            profileResolver: resolver
        )
        #expect(Self.decodedModel(rewritten) == "deepseek-v4-flash")
    }

    @Test
    func bodyModelRewritePreservesOtherBodyFields() {
        // Round-trip — only the `model` value mutates; other top-
        // level fields (max_tokens, messages, system, tools, etc.)
        // pass through identically.
        let body = Data(#"""
            {
              "model": "claude-opus-4-7",
              "max_tokens": 4096,
              "system": "You are helpful.",
              "messages": [{"role":"user","content":"hi"}],
              "temperature": 0.7,
              "tools": [{"name":"calc"}]
            }
            """#.utf8)
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            body,
            path: "/v1/messages",
            profileResolver: resolver
        )
        guard let json = try? JSONSerialization.jsonObject(with: rewritten) as? [String: Any] else {
            Issue.record("rewritten body did not parse as JSON object")
            return
        }
        #expect(json["model"] as? String == "deepseek-v4-pro")
        #expect(json["max_tokens"] as? Int == 4096)
        #expect(json["system"] as? String == "You are helpful.")
        #expect(json["temperature"] as? Double == 0.7)
        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "user")
        #expect(messages?.first?["content"] as? String == "hi")
        let tools = json["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "calc")
    }

    @Test
    func bodyModelRewriteFailsClosedOnMissingModelField() {
        // Don't fabricate a `model` field the client didn't send —
        // pass through unchanged so upstream's missing-model error
        // surfaces directly. (Quieter alternative: silently injecting
        // makes a debugging session more confusing because the proxy
        // appears to spawn a model from nowhere.)
        let body = Data(#"{"max_tokens":1,"messages":[]}"#.utf8)
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            body,
            path: "/v1/messages",
            profileResolver: resolver
        )
        #expect(rewritten == body)
    }

    @Test
    func directProfileVariantRewritesWithoutResolverIndirection() {
        // T2 introduced `rewriteModelFieldIfNeeded(_:path:profile:)`
        // — the proxy hot path resolves once at request entry, then
        // passes the resolved profile here, eliminating the late
        // `currentActiveProfile()` read that risked tearing a
        // request between resolution and forward. Verify the new
        // direct-profile entry produces the same body mutation as
        // the resolver-based variant for an equivalent profile.
        let direct = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            Self.bodyAnthropicOpus,
            path: "/v1/messages",
            profile: BuiltinProfiles.deepseekV4Pro
        )
        #expect(Self.decodedModel(direct) == "deepseek-v4-pro")

        // Direct variant also no-ops on a passthrough profile.
        let untouched = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            Self.bodyAnthropicOpus,
            path: "/v1/messages",
            profile: BuiltinProfiles.anthropicNative
        )
        #expect(untouched == Self.bodyAnthropicOpus)
    }

    @Test
    func nonRewriteablePathPassesThrough() {
        // /v1/models is an admin endpoint that doesn't take a body
        // model field; we must not blindly rewrite it just because
        // the active profile has a modelOverride.
        let body = Self.bodyAnthropicOpus
        let resolver = Self.makeResolver(active: BuiltinProfiles.deepseekV4Pro)
        let rewritten = LLMRequestRewriter.rewriteModelFieldIfNeeded(
            body,
            path: "/v1/models",
            profileResolver: resolver
        )
        #expect(rewritten == body)
    }
}
