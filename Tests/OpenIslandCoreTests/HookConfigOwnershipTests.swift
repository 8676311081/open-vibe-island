import Testing
import Foundation
@testable import OpenIslandCore

/// H-5 helper: verifies the JSON walker correctly partitions hook
/// entries into Open-Island-managed vs user-authored, regardless of
/// the four supported config-file shapes.
///
/// `describeExistingConfig` itself is fire-and-forget (emits
/// `os_log`, returns Void), so these tests target the internal
/// `countHookEntries` directly.
@Suite struct HookConfigOwnershipTests {

    @Test
    func emptyDataYieldsZeros() {
        let counts = HookConfigOwnership.countHookEntries(
            in: Data(),
            managedCommandSubstring: "OpenIslandHooks"
        )
        #expect(counts.managed == 0)
        #expect(counts.userAuthored == 0)
    }

    @Test
    func nonObjectRootYieldsZeros() {
        let counts = HookConfigOwnership.countHookEntries(
            in: Data(#"["not an object"]"#.utf8),
            managedCommandSubstring: "OpenIslandHooks"
        )
        #expect(counts.managed == 0)
        #expect(counts.userAuthored == 0)
    }

    @Test
    func managedOnlyConfig() {
        let json = """
        {
          "hooks": {
            "PreToolUse": [
              {"matcher": "*", "hooks": [
                {"type": "command", "command": "/Library/Application Support/OpenIsland/bin/OpenIslandHooks --source claude"}
              ]}
            ]
          }
        }
        """
        let counts = HookConfigOwnership.countHookEntries(
            in: Data(json.utf8),
            managedCommandSubstring: "OpenIslandHooks"
        )
        #expect(counts.managed == 1)
        #expect(counts.userAuthored == 0)
    }

    @Test
    func userAuthoredOnlyConfig() {
        let json = """
        {
          "hooks": {
            "PostToolUse": [
              {"matcher": "Edit", "hooks": [
                {"type": "command", "command": "/usr/local/bin/my-formatter"}
              ]}
            ]
          }
        }
        """
        let counts = HookConfigOwnership.countHookEntries(
            in: Data(json.utf8),
            managedCommandSubstring: "OpenIslandHooks"
        )
        #expect(counts.managed == 0)
        #expect(counts.userAuthored == 1)
    }

    @Test
    func mixedConfigPartitionsCorrectly() {
        // Realistic case: user has 2 of their own hooks plus
        // Open Island's auto-installed managed hooks across 2 events.
        let json = """
        {
          "hooks": {
            "PreToolUse": [
              {"matcher": "*", "hooks": [
                {"type": "command", "command": "/Library/Application Support/OpenIsland/bin/OpenIslandHooks --source claude"},
                {"type": "command", "command": "/usr/local/bin/my-pre-formatter"}
              ]}
            ],
            "PostToolUse": [
              {"matcher": "Edit", "hooks": [
                {"type": "command", "command": "/usr/local/bin/my-post-formatter"}
              ]}
            ],
            "Notification": [
              {"matcher": "*", "hooks": [
                {"type": "command", "command": "/Library/Application Support/OpenIsland/bin/OpenIslandHooks --source claude"}
              ]}
            ]
          }
        }
        """
        let counts = HookConfigOwnership.countHookEntries(
            in: Data(json.utf8),
            managedCommandSubstring: "OpenIslandHooks"
        )
        #expect(counts.managed == 2)
        #expect(counts.userAuthored == 2)
    }

    @Test
    func malformedJSONYieldsZerosNotCrash() {
        let counts = HookConfigOwnership.countHookEntries(
            in: Data(#"{"hooks": [oops"#.utf8),
            managedCommandSubstring: "OpenIslandHooks"
        )
        #expect(counts.managed == 0)
        #expect(counts.userAuthored == 0)
    }
}
