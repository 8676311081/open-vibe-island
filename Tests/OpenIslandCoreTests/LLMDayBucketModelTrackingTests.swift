import Foundation
import Testing
@testable import OpenIslandCore

struct LLMDayBucketModelTrackingTests {
    @Test
    func decodingLegacyBucketYieldsEmptyModelDicts() throws {
        let legacy = Data(#"""
            {
              "turns": 10,
              "tokensIn": 5000,
              "tokensOut": 2000,
              "inputTokens": 4000,
              "cacheReadTokens": 1000,
              "cacheCreationTokens": 0,
              "costUsd": 0.025,
              "unpricedTurns": 0,
              "duplicateToolCalls": 0,
              "unusedToolTokensWasted": 0
            }
            """#.utf8)
        let bucket = try JSONDecoder().decode(LLMDayBucket.self, from: legacy)
        #expect(bucket.turns == 10)
        #expect(bucket.costUsd == 0.025)
        #expect(bucket.modelTurns == [:])
        #expect(bucket.modelCosts == [:])
    }

    @Test
    func decodingBucketWithModelFieldsRoundTrips() throws {
        let original = LLMDayBucket(
            turns: 5,
            costUsd: 0.15,
            modelTurns: ["claude-sonnet-4-5": 3, "deepseek-v4-pro": 2],
            modelCosts: ["claude-sonnet-4-5": 0.09, "deepseek-v4-pro": 0.06]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMDayBucket.self, from: encoded)
        #expect(decoded.modelTurns == original.modelTurns)
        #expect(decoded.modelCosts == original.modelCosts)
    }

    @Test
    func recordWithModelAccumulatesModelCostsAndTurns() async {
        let storeURL = tempURL()
        let store = LLMStatsStore(url: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        await store.recordRequestCompletion(
            client: .claudeCode,
            model: "claude-sonnet-4-5",
            usage: TokenUsage(input: 1_000_000, output: 500_000),
            costUsd: 4.50
        )
        await store.recordRequestCompletion(
            client: .claudeCode,
            model: "claude-sonnet-4-5",
            usage: TokenUsage(input: 500_000, output: 200_000),
            costUsd: 2.00
        )

        let snap = await store.currentSnapshot()
        let todayKey = Self.todayKey()
        let bucket = snap.days[todayKey]?["claude-code"]
        #expect(bucket?.turns == 2)
        #expect(bucket?.modelTurns["claude-sonnet-4-5"] == 2)
        #expect(abs((bucket?.modelCosts["claude-sonnet-4-5"] ?? 0) - 6.50) < 0.0001)
    }

    @Test
    func recordWithNilModelDoesNotTouchModelDicts() async {
        let storeURL = tempURL()
        let store = LLMStatsStore(url: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        await store.recordRequestCompletion(
            client: .claudeCode,
            model: nil,
            usage: TokenUsage(input: 1000, output: 500),
            costUsd: 0.005
        )

        let snap = await store.currentSnapshot()
        let todayKey = Self.todayKey()
        let bucket = snap.days[todayKey]?["claude-code"]
        #expect(bucket?.turns == 1)
        #expect(bucket?.modelTurns == [:])
        #expect(bucket?.modelCosts == [:])
    }

    @Test
    func unpricedModelRecordsTurnButNoCost() async {
        let storeURL = tempURL()
        let store = LLMStatsStore(url: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        await store.recordRequestCompletion(
            client: .claudeCode,
            model: "some-unknown-model",
            usage: TokenUsage(input: 1000, output: 500),
            costUsd: nil
        )

        let snap = await store.currentSnapshot()
        let todayKey = Self.todayKey()
        let bucket = snap.days[todayKey]?["claude-code"]
        #expect(bucket?.turns == 1)
        #expect(bucket?.unpricedTurns == 1)
        #expect(bucket?.modelTurns["some-unknown-model"] == 1)
        #expect(bucket?.modelCosts["some-unknown-model"] == nil)
    }

    @Test
    func multipleModelsAcrossClientsAccumulateCorrectly() async {
        let storeURL = tempURL()
        let store = LLMStatsStore(url: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        await store.recordRequestCompletion(
            client: .claudeCode,
            model: "claude-opus-4-7",
            usage: TokenUsage(input: 1_000_000, output: 200_000),
            costUsd: 5.50
        )
        await store.recordRequestCompletion(
            client: .claudeCode,
            model: "deepseek-v4-pro",
            usage: TokenUsage(input: 500_000, output: 100_000),
            costUsd: 0.30
        )
        await store.recordRequestCompletion(
            client: .codex,
            model: "gpt-5",
            usage: TokenUsage(input: 2_000_000, output: 500_000),
            costUsd: 7.50
        )

        let snap = await store.currentSnapshot()
        let todayKey = Self.todayKey()

        let cc = snap.days[todayKey]?["claude-code"]
        #expect(cc?.turns == 2)
        #expect(abs((cc?.costUsd ?? 0) - 5.80) < 0.001)
        #expect(cc?.modelTurns["claude-opus-4-7"] == 1)
        #expect(abs((cc?.modelCosts["claude-opus-4-7"] ?? 0) - 5.50) < 0.001)
        #expect(cc?.modelTurns["deepseek-v4-pro"] == 1)
        #expect(abs((cc?.modelCosts["deepseek-v4-pro"] ?? 0) - 0.30) < 0.001)

        let cx = snap.days[todayKey]?["codex"]
        #expect(cx?.turns == 1)
        #expect(cx?.modelTurns["gpt-5"] == 1)
        #expect(abs((cx?.modelCosts["gpt-5"] ?? 0) - 7.50) < 0.001)
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llm-model-tracking-test-\(UUID().uuidString).json")
    }

    private static func todayKey() -> String {
        // Mirror what LLMStatsStore.dayKey writes — local timezone,
        // not UTC. The store keys buckets by the user's wall-clock
        // calendar day; using a UTC formatter here made this suite
        // intermittently fail at the local-vs-UTC date boundary.
        LLMStatsStore.dayKey(for: Date())
    }
}
