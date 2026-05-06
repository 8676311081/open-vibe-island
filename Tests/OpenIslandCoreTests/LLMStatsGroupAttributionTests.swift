import Testing
import Foundation
@testable import OpenIslandCore

/// P4 of the three-port routing rollout: per-`ProviderGroup`
/// attribution inside `LLMDayBucket`. UI commits land on top of
/// these dictionaries — `groupTurns`, `groupCosts`, `groupTokens`
/// — to render "today on 9710" / "today on 9711" without re-
/// deriving the group from the model name.
@Suite struct LLMStatsGroupAttributionTests {

    private func makeStore() async -> LLMStatsStore {
        // Use a temp file so persisted JSON doesn't bleed across
        // tests. The actor's persist() is synchronous within the
        // recordRequestCompletion call, so by the time we read
        // currentSnapshot() the on-disk file is consistent.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-stats-attribution-\(UUID().uuidString).json")
        let store = LLMStatsStore(url: tmp)
        return store
    }

    @Test
    func recordsGroupTurnsCostsAndTokensWhenProviderGroupSupplied() async {
        let store = await makeStore()
        let day = Date()
        await store.recordRequestCompletion(
            date: day,
            client: .claudeCode,
            model: "deepseek-v4-pro",
            usage: TokenUsage(input: 100, cacheWrite: 0, cacheRead: 0, output: 50),
            costUsd: 0.012,
            providerGroup: .deepseek
        )
        let snapshot = await store.currentSnapshot()
        let key = LLMStatsStore.dayKey(for: day)
        let bucket = snapshot.days[key]?[LLMClient.claudeCode.rawValue]
        #expect(bucket?.groupTurns["deepseek"] == 1)
        #expect(bucket?.groupTokens["deepseek"] == 150)  // input + cacheWrite + cacheRead + output
        if let cost = bucket?.groupCosts["deepseek"] {
            #expect(abs(cost - 0.012) < 1e-9)
        } else {
            Issue.record("deepseek groupCost missing")
        }
    }

    @Test
    func multipleGroupsAccumulateInDistinctKeys() async {
        let store = await makeStore()
        let day = Date()
        await store.recordRequestCompletion(
            date: day,
            client: .claudeCode,
            model: "claude-sonnet-4-5",
            usage: TokenUsage(input: 200, cacheWrite: 0, cacheRead: 0, output: 100),
            costUsd: 0.005,
            providerGroup: .officialClaude
        )
        await store.recordRequestCompletion(
            date: day,
            client: .claudeCode,
            model: "deepseek-v4-pro",
            usage: TokenUsage(input: 100, cacheWrite: 0, cacheRead: 0, output: 50),
            costUsd: 0.012,
            providerGroup: .deepseek
        )
        let snapshot = await store.currentSnapshot()
        let key = LLMStatsStore.dayKey(for: day)
        let bucket = snapshot.days[key]?[LLMClient.claudeCode.rawValue]
        #expect(bucket?.groupTurns.count == 2)
        #expect(bucket?.groupTurns["officialClaude"] == 1)
        #expect(bucket?.groupTurns["deepseek"] == 1)
        // Group sums equal bucket totals (each turn was attributed
        // to exactly one group).
        let groupTokenSum = bucket?.groupTokens.values.reduce(0, +) ?? 0
        let bucketTokenSum = (bucket?.tokensIn ?? 0) + (bucket?.tokensOut ?? 0)
        #expect(groupTokenSum == bucketTokenSum)
    }

    @Test
    func nilProviderGroupOmitsGroupAttributionEntirely() async {
        // Legacy/fixture path — a caller that doesn't pass
        // providerGroup must not produce any group entries (we'd
        // rather show `—` in the UI than a misattributed bucket).
        let store = await makeStore()
        let day = Date()
        await store.recordRequestCompletion(
            date: day,
            client: .claudeCode,
            model: "claude-sonnet-4-5",
            usage: TokenUsage(input: 100, cacheWrite: 0, cacheRead: 0, output: 50),
            costUsd: 0.005,
            providerGroup: nil
        )
        let snapshot = await store.currentSnapshot()
        let key = LLMStatsStore.dayKey(for: day)
        let bucket = snapshot.days[key]?[LLMClient.claudeCode.rawValue]
        #expect(bucket?.groupTurns.isEmpty == true)
        #expect(bucket?.groupCosts.isEmpty == true)
        #expect(bucket?.groupTokens.isEmpty == true)
        // But the bucket totals still count the turn — we don't lose
        // data, just the attribution dimension.
        #expect(bucket?.turns == 1)
        #expect(bucket?.tokensOut == 50)
    }

    @Test
    func unpricedGroupTurnSkipsGroupCostButCountsTurnAndTokens() async {
        // Model not in the pricing table → costUsd=nil. The bucket
        // increments unpricedTurns and skips bucket-level costUsd;
        // group attribution should follow the same rule (count the
        // turn + tokens, but no cost contribution).
        let store = await makeStore()
        let day = Date()
        await store.recordRequestCompletion(
            date: day,
            client: .claudeCode,
            model: "unknown-model-x",
            usage: TokenUsage(input: 100, cacheWrite: 0, cacheRead: 0, output: 50),
            costUsd: nil,
            providerGroup: .thirdParty
        )
        let snapshot = await store.currentSnapshot()
        let key = LLMStatsStore.dayKey(for: day)
        let bucket = snapshot.days[key]?[LLMClient.claudeCode.rawValue]
        #expect(bucket?.groupTurns["thirdParty"] == 1)
        #expect(bucket?.groupTokens["thirdParty"] == 150)
        #expect(bucket?.groupCosts["thirdParty"] == nil)  // never set on nil cost
        #expect(bucket?.unpricedTurns == 1)
    }

    // MARK: - Codable compatibility

    @Test
    func legacyBucketJsonWithoutGroupFieldsDecodesEmpty() throws {
        // Simulates a stats.json written by the pre-three-port app:
        // no groupTurns/groupCosts/groupTokens keys at all. Round-
        // trip must succeed with the new fields defaulting to [:].
        let legacyJSON = """
        {
            "turns": 5,
            "tokensIn": 1000,
            "tokensOut": 500,
            "inputTokens": 800,
            "cacheReadTokens": 200,
            "cacheCreationTokens": 0,
            "costUsd": 0.025,
            "unpricedTurns": 0,
            "modelTurns": {"claude-sonnet-4-5": 5},
            "modelCosts": {"claude-sonnet-4-5": 0.025},
            "modelTokens": {"claude-sonnet-4-5": 1500},
            "modelInputTokens": {"claude-sonnet-4-5": 800},
            "modelCacheReadTokens": {"claude-sonnet-4-5": 200},
            "modelCacheCreationTokens": {"claude-sonnet-4-5": 0},
            "duplicateToolCalls": 0,
            "unusedToolTokensWasted": 0
        }
        """
        let bucket = try JSONDecoder().decode(
            LLMDayBucket.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(bucket.turns == 5)
        #expect(bucket.tokensIn == 1000)
        #expect(bucket.modelTurns["claude-sonnet-4-5"] == 5)
        // The new fields default to [:] — UI renders "—" for these
        // until a fresh turn rebuilds the attribution.
        #expect(bucket.groupTurns.isEmpty)
        #expect(bucket.groupCosts.isEmpty)
        #expect(bucket.groupTokens.isEmpty)
    }

    @Test
    func roundtripWithGroupFieldsPreservesAttribution() throws {
        let original = LLMDayBucket(
            turns: 3,
            tokensIn: 500,
            tokensOut: 200,
            costUsd: 0.015,
            modelTurns: ["deepseek-v4-pro": 3],
            modelCosts: ["deepseek-v4-pro": 0.015],
            modelTokens: ["deepseek-v4-pro": 700],
            groupTurns: ["deepseek": 3],
            groupCosts: ["deepseek": 0.015],
            groupTokens: ["deepseek": 700]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMDayBucket.self, from: data)
        #expect(decoded == original)
    }
}
