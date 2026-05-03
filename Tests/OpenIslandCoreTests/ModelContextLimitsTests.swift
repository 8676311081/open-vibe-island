import Foundation
import Testing
@testable import OpenIslandCore

struct ModelContextLimitsTests {
    @Test
    func anthropicOpus47ResolvesTo200K() {
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7") == 200_000)
    }

    @Test
    func anthropicOpus47BracketedOneMResolvesTo1M() {
        // Claude CLI emits `claude-opus-4-7[1m]` for the 1M-context
        // SKU. Without an explicit row this used to fall through
        // longest-prefix matcher onto the 200K bare row and quietly
        // misclassify the window — Open Island would flash a red
        // 100% context-fill banner at 200K used (62.5K of 1M
        // actually). The bracket entry must win over the bare row.
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7[1m]") == 1_000_000)
    }

    @Test
    func anthropicOpus47DashOneMResolvesTo1M() {
        // `-1m` suffix is the canonical-style SKU naming Anthropic
        // uses for extended-context variants (e.g. claude-sonnet-4-5
        // -1m). Tested even though Open Island doesn't currently
        // see this form for opus, because Claude Code env override
        // can pin to it and we want the table to be self-consistent
        // across naming variants.
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7-1m") == 1_000_000)
    }

    @Test
    func datedSuffixWithoutOneMStaysAt200K() {
        // Regression guard: `-20251205` follows the bare `4-7` row,
        // not the `4-7-1m` row. Crucial because longest-prefix could
        // theoretically partially match `4-7-1` against `4-7-1m` —
        // verify the two rows route their respective ids and don't
        // bleed into each other.
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7-20251205") == 200_000)
        // And the 1M variant with its own dated suffix still
        // resolves to 1M (longest prefix `claude-opus-4-7-1m` wins).
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-opus-4-7-1m-20251205") == 1_000_000)
    }

    @Test
    func anthropicSonnet45OneMResolvesTo1M() {
        // Anthropic's original 1M beta SKU from 2025; verifies the
        // longer prefix wins over `claude-sonnet-4-5`.
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-sonnet-4-5-1m") == 1_000_000)
        #expect(ModelContextLimits.maxContextTokens(forModel: "claude-sonnet-4-5") == 200_000)
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
