import Foundation
import Testing
@testable import OpenIslandApp

/// Structural invariants on `SettingsTab` / `SettingsSection`. These
/// don't replace the round-trip AXOutline count check (SwiftUI runtime
/// can still drop rows even when the model is correct — that's exactly
/// the bug this commit fixes), but they pin the case-list shape so a
/// future contributor who forgets to assign a new `SettingsTab` case
/// to a section, or who introduces an `id` collision, fails fast at
/// `swift test` rather than at user smoke.
struct SettingsTabIntegrityTests {
    @Test
    func allSettingsTabsHaveUniqueIDs() {
        let allIDs = SettingsTab.allCases.map(\.id)
        // On failure, swift-testing dumps both sides of the
        // expression so the colliding ids are visible verbatim.
        #expect(allIDs.count == Set(allIDs).count)
    }

    @Test
    func allSettingsTabsBelongToSomeSection() {
        let allTabs = Set(SettingsTab.allCases)
        let sectionedTabs = Set(SettingsSection.allCases.flatMap(\.tabs))
        // On failure, swift-testing dumps the symmetric difference
        // by virtue of comparing the two sets — we don't need a
        // custom message.
        #expect(allTabs == sectionedTabs)
    }

    @Test
    func systemSectionContainsAllExpectedTabs() {
        // The `.autoResponse` and `.llmSpend` rows were the two that
        // the SwiftUI bug dropped. Assert they're at least *modeled*
        // in the right section here so the model contract stays
        // pinned, even if a future SwiftUI rewrite reintroduces the
        // dropping behavior.
        let systemTabs = SettingsSection.system.tabs
        #expect(systemTabs.contains(.autoResponse))
        #expect(systemTabs.contains(.llmSpend))
    }
}
