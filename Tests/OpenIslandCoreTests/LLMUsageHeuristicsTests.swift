import Foundation
import Testing
@testable import OpenIslandCore

struct LLMClientFromUserAgentTests {
    @Test
    func nilUAReturnsUnknown() {
        #expect(LLMUsageHeuristics.clientFromUserAgent(nil) == .unknown)
    }

    @Test
    func emptyUAReturnsUnknown() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("") == .unknown)
    }

    @Test
    func claudeCLIIsClaudeCode() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("claude-cli/1.2.3") == .claudeCode)
    }

    @Test
    func anthropicSDKIsClaudeCode() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("anthropic-sdk-python/0.40.0") == .claudeCode)
    }

    @Test
    func anthropicTypescriptSDKIsClaudeCode() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("anthropic-ai-typescript/0.30.1") == .claudeCode)
    }

    @Test
    func codexCLIIsCodex() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("codex_cli_rs/0.5.0") == .codex)
    }

    @Test
    func openAICodexFramingStillCodex() {
        // Some Codex builds layer "OpenAI/Python ... codex" — codex token
        // wins regardless of position.
        #expect(LLMUsageHeuristics.clientFromUserAgent("OpenAI/Python 1.0.0 codex-cli") == .codex)
    }

    @Test
    func cursorIsCursor() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("Cursor/0.42.0") == .cursor)
    }

    @Test
    func cursorWithAnthropicLayeringStillCursor() {
        // Cursor talks to Anthropic too; the cursor token must win.
        #expect(
            LLMUsageHeuristics.clientFromUserAgent("Cursor/0.42 anthropic-sdk-typescript/0.30.1") == .cursor
        )
    }

    @Test
    func curlIsUnknown() {
        #expect(LLMUsageHeuristics.clientFromUserAgent("curl/8.0.1") == .unknown)
    }

    @Test
    func rawOpenAISDKIsUnknown() {
        // openai-python without a Codex framing — we don't claim it.
        #expect(LLMUsageHeuristics.clientFromUserAgent("OpenAI/Python 1.0.0") == .unknown)
    }
}

struct LLMPricingTests {
    @Test
    func sonnet45DateSuffixedResolves() {
        let p = LLMPricing.priceFor(model: "claude-sonnet-4-5-20250929")
        #expect(p?.inputPerMTok == 3.00)
        #expect(p?.outputPerMTok == 15.00)
    }

    @Test
    func gpt4oMiniRowExists() {
        let p = LLMPricing.priceFor(model: "gpt-4o-mini")
        #expect(p?.inputPerMTok == 0.15)
        #expect(p?.outputPerMTok == 0.60)
    }

    @Test
    func unknownModelReturnsNil() {
        #expect(LLMPricing.priceFor(model: "made-up-model-9000") == nil)
    }

    @Test
    func costMathOnSonnet() {
        // 1M input + 200K output on sonnet-4.5 = $3 + 0.2 * $15 = $6.
        let usage = TokenUsage(input: 1_000_000, output: 200_000)
        let cost = LLMPricing.costUSD(model: "claude-sonnet-4-5", usage: usage)
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 6.00) < 1e-9)
    }

    @Test
    func cacheTokensPriced() {
        // 1M cache write @ $3.75 + 1M cache read @ $0.30 on sonnet.
        let usage = TokenUsage(cacheWrite: 1_000_000, cacheRead: 1_000_000)
        let cost = LLMPricing.costUSD(model: "claude-sonnet-4-5", usage: usage)
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - (3.75 + 0.30)) < 1e-9)
    }

    @Test
    func unknownModelReturnsNilCost() {
        // Silent zero would hide pricing-table drift — make the caller
        // distinguish "we have no price" from "the math came out to 0".
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        #expect(LLMPricing.costUSD(model: "made-up-model-9000", usage: usage) == nil)
        #expect(LLMPricing.costUSD(model: nil, usage: usage) == nil)
    }
}

struct LLMProxyUpstreamCombineTests {
    @Test
    func directProviderConcat() {
        let url = LLMProxyServer.combineUpstream(
            base: URL(string: "https://api.openai.com")!,
            requestTarget: "/v1/chat/completions"
        )
        #expect(url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test
    func gatewayWithPathPrefixConcat() {
        let url = LLMProxyServer.combineUpstream(
            base: URL(string: "https://api2.tabcode.cc/openai/plus")!,
            requestTarget: "/v1/responses"
        )
        #expect(url?.absoluteString == "https://api2.tabcode.cc/openai/plus/v1/responses")
    }

    @Test
    func trailingSlashOnBaseTrimmed() {
        let url = LLMProxyServer.combineUpstream(
            base: URL(string: "https://example.com/gw/")!,
            requestTarget: "/v1/messages"
        )
        #expect(url?.absoluteString == "https://example.com/gw/v1/messages")
    }

    @Test
    func queryStringOnRequestTargetPreserved() {
        let url = LLMProxyServer.combineUpstream(
            base: URL(string: "https://api.openai.com")!,
            requestTarget: "/v1/responses?stream=true"
        )
        #expect(url?.absoluteString == "https://api.openai.com/v1/responses?stream=true")
    }
}

struct LLMRequestRewriterTests {
    @Test
    func nonStreamingRequestNotTouched() {
        let body = #"{"model":"gpt-5","messages":[{"role":"user","content":"hi"}]}"#.data(using: .utf8)!
        let out = LLMRequestRewriter.rewrittenChatCompletionsBody(body)
        #expect(out == body)
    }

    @Test
    func streamingWithoutOptionGetsInjection() {
        let body = #"{"stream":true,"model":"gpt-5","messages":[]}"#.data(using: .utf8)!
        let out = LLMRequestRewriter.rewrittenChatCompletionsBody(body)
        let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
        let opts = json?["stream_options"] as? [String: Any]
        #expect((opts?["include_usage"] as? Bool) == true)
    }

    @Test
    func explicitFalseRespected() {
        let body = #"{"stream":true,"stream_options":{"include_usage":false},"model":"gpt-5","messages":[]}"#.data(using: .utf8)!
        let out = LLMRequestRewriter.rewrittenChatCompletionsBody(body)
        let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
        let opts = json?["stream_options"] as? [String: Any]
        // Round-trip: still false, not flipped to true.
        #expect((opts?["include_usage"] as? Bool) == false)
    }

    @Test
    func nonChatCompletionsPathSkipsRewrite() {
        #expect(LLMRequestRewriter.shouldRewrite(path: "/v1/chat/completions") == true)
        #expect(LLMRequestRewriter.shouldRewrite(path: "/v1/responses") == false)
        #expect(LLMRequestRewriter.shouldRewrite(path: "/v1/messages") == false)
    }
}

struct LLMStatsStoreTests {
    @Test
    func duplicateToolUseDetectedWithinWindow() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-stats-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LLMStatsStore(url: tmp)
        let now = Date()
        let dup1 = await store.recordToolUse(
            client: .claudeCode, name: "Read", inputHash: "abc", at: now
        )
        let dup2 = await store.recordToolUse(
            client: .claudeCode, name: "Read", inputHash: "abc", at: now.addingTimeInterval(60)
        )
        #expect(dup1 == false)
        #expect(dup2 == true)
    }

    @Test
    func duplicateOutsideWindowIsNotADuplicate() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-stats-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LLMStatsStore(url: tmp)
        let now = Date()
        _ = await store.recordToolUse(
            client: .claudeCode, name: "Read", inputHash: "abc", at: now
        )
        let dup = await store.recordToolUse(
            client: .claudeCode,
            name: "Read",
            inputHash: "abc",
            at: now.addingTimeInterval(LLMStatsStore.duplicateWindow + 1)
        )
        #expect(dup == false)
    }

    @Test
    func recordPersistsAtomically() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-stats-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LLMStatsStore(url: tmp)
        let usage = TokenUsage(input: 1000, cacheRead: 500, output: 200)
        await store.recordRequestCompletion(
            date: Date(),
            client: .claudeCode,
            usage: usage,
            costUsd: 0.42 as Double?
        )
        let raw = try Data(contentsOf: tmp)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(LLMStatsSnapshot.self, from: raw)
        let day = snap.days.values.first
        let bucket = day?[LLMClient.claudeCode.rawValue]
        #expect(bucket?.turns == 1)
        #expect(bucket?.tokensIn == 1500)
        #expect(bucket?.tokensOut == 200)
        #expect(abs((bucket?.costUsd ?? 0) - 0.42) < 1e-9)
        #expect(bucket?.unpricedTurns == 0)
    }

    @Test
    func unpricedTurnsBumpedWhenCostNil() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-stats-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LLMStatsStore(url: tmp)
        await store.recordRequestCompletion(
            date: Date(),
            client: .codex,
            usage: TokenUsage(input: 100, output: 50),
            costUsd: nil
        )
        let snap = await store.currentSnapshot()
        let bucket = snap.days.values.first?[LLMClient.codex.rawValue]
        #expect(bucket?.turns == 1)
        #expect(bucket?.tokensIn == 100)
        #expect(bucket?.unpricedTurns == 1)
        #expect((bucket?.costUsd ?? -1) == 0)
    }
}
