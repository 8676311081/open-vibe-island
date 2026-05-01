import Foundation
import Testing
@testable import OpenIslandCore

struct ModelContextLimitsTests {
    @Test
    func anthropicOpus47ResolvesTo200K() {
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7") == 200_000)
    }

    @Test
    func anthropicSonnet46ResolvesTo200K() {
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-sonnet-4-6") == 200_000)
    }

    @Test
    func anthropicHaiku45ResolvesTo200K() {
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-haiku-4-5") == 200_000)
    }

    @Test
    func datedSuffixResolvesViaLongestPrefix() {
        // claude-opus-4-7-20251205 → matches the claude-opus-4-7 row
        // (`-20251205` is just the dated checkpoint suffix).
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7-20251205") == 200_000)
    }

    @Test
    func longestPrefixWinsBetweenSiblings() {
        // claude-opus-4-7 wins over claude-opus-4-6 because its
        // prefix is fully longer (`4-7` ≠ `4-6` in the leading
        // bytes that match `claude-opus-4-7-20251205`).
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-6-20251101") == 200_000)
    }

    @Test
    func unknownGPTModelReturnsNilNotFabricated() {
        // GPT family is deliberately omitted from the table while
        // the upstream version landscape is in flux. UI must show
        // "—" rather than a wrong percentage — that's the
        // observable contract this test pins.
        #expect(ModelContextLimits.maxContextTokens(forModel: "gpt-5") == nil)
        #expect(ModelContextLimits.maxContextTokens(forModel: "gpt-5.4-mini") == nil)
        #expect(ModelContextLimits.maxContextTokens(forModel: "gpt-4o") == nil)
        #expect(ModelContextLimits.maxContextTokens(forModel: "o3-mini") == nil)
    }

    @Test
    func unknownAnthropicVariantReturnsNil() {
        // Future hypothetical variant we haven't verified — must
        // refuse to guess.
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-5-0") == nil)
        #expect(ModelContextLimits.maxContextTokens(forModel: "totally-fake-model") == nil)
    }

    @Test
    func emptyStringReturnsNil() {
        #expect(ModelContextLimits.maxContextTokens(forModel: "") == nil)
    }
}
