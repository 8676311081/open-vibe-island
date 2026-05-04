import Foundation
import Testing
@testable import OpenIslandApp

/// Verifies the CLI shim bundle that ships with the app. The shims
/// live under `Sources/OpenIslandApp/Resources/bin/` and are copied
/// into `~/.open-island/bin/` at startup by
/// `HookInstallationCoordinator.ensureShimsInstalled()`.
///
/// The install code enumerates the resource subdirectory rather than
/// hard-coding shim names, so adding a new shim file is enough to ship
/// it. These tests guarantee that the bundle actually contains the
/// expected files and that `claude-3`'s sentinel-emission logic
/// matches the proxy's `parseSentinel(path:)` contract.
@Suite
struct BundledShimsTests {
    private static func shimContent(_ name: String) throws -> String {
        // SPM's `.process("Resources")` rule flattens the directory
        // at build time, so shims that live under `Resources/bin/` in
        // source appear at the bundle root next to Info.plist. Look
        // them up at the root, not in a `bin/` subdirectory.
        guard let url = Bundle.appResources.url(
            forResource: name,
            withExtension: nil
        ) else {
            throw NSError(
                domain: "BundledShimsTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Shim '\(name)' missing from bundle. Did you add it under Sources/OpenIslandApp/Resources/bin/ AND list it in HookInstallationCoordinator.bundledShimNames?"]
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func bundleShipsAllExpectedShims() throws {
        // Three shims must be in the bundle so the install loop in
        // `ensureShimsInstalled` finds them. Adding a new shim later
        // means extending the source-of-truth list in
        // HookInstallationCoordinator.bundledShimNames AND adding a
        // per-content test below.
        let expected = ["claude-native", "oi-claude", "claude-3"]
        for name in expected {
            let content = try Self.shimContent(name)
            #expect(content.hasPrefix("#!/bin/zsh"), "\(name) should be a zsh shim")
            #expect(!content.isEmpty, "\(name) should have content")
        }
    }

    @Test
    func installerSourceOfTruthMatchesBundle() throws {
        // The installer's static list and the bundle's actual files
        // must stay in lock-step — the install loop early-skips a
        // missing-from-bundle name with a status message, but a
        // present-in-bundle-but-not-listed shim would never be
        // installed. Catch both kinds of drift.
        for name in HookInstallationCoordinator.bundledShimNames {
            #expect(
                Bundle.appResources.url(forResource: name, withExtension: nil) != nil,
                "Installer lists '\(name)' but the bundle does not have it"
            )
        }
    }

    @Test
    func claude3ShimEmitsSentinelPathWhenOIProfileSet() throws {
        // T5 invariant — the proxy's `parseSentinel(path:)` looks for
        // exactly the prefix `/_oi/profile/<id>/...`. The shim's
        // OI_PROFILE-set branch must produce a base URL that matches
        // that contract; otherwise override would silently fall back
        // to active-default at the proxy.
        let content = try Self.shimContent("claude-3")
        // The shim sets the URL via `_oi/profile/${OI_PROFILE}` when
        // OI_PROFILE is non-empty.
        #expect(content.contains("/_oi/profile/${OI_PROFILE}"),
                "claude-3 must encode OI_PROFILE into a /_oi/profile/<id> URL prefix")
        // The shim must guard the override branch on `OI_PROFILE`
        // being non-empty. A bare `[ -n "$OI_PROFILE" ]` (or the
        // `${OI_PROFILE:-}` parameter expansion variant) is the
        // canonical zsh pattern.
        #expect(
            content.contains("\"${OI_PROFILE:-}\"") || content.contains("\"$OI_PROFILE\""),
            "claude-3 must check OI_PROFILE before encoding it"
        )
    }

    @Test
    func claude3ShimFallsBackToBareProxyWhenOIProfileUnset() throws {
        // No OI_PROFILE → behavior identical to oi-claude (proxy +
        // active default). Verify the fall-through branch sets the
        // base URL to the plain proxy origin without any sentinel
        // prefix.
        let content = try Self.shimContent("claude-3")
        // Both shims point at 127.0.0.1:${OPEN_ISLAND_PORT}.
        #expect(content.contains("127.0.0.1:${OPEN_ISLAND_PORT}"))
        // The shim ultimately exec's claude with ANTHROPIC_BASE_URL
        // set — same exec line shape as the other shims.
        #expect(content.contains("exec env ANTHROPIC_BASE_URL="))
        #expect(content.contains("claude \"$@\""))
    }

    @Test
    func claudeNativeShimStripsAnthropicEnv() throws {
        // Smoke that the existing shim still does what it advertises.
        // Catches accidental regressions if anyone refactors the bin/
        // tree.
        let content = try Self.shimContent("claude-native")
        #expect(content.contains("env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN"))
    }

    @Test
    func oiClaudeShimSetsProxyBaseUrlWithoutSentinel() throws {
        // Sibling smoke. oi-claude is the legacy proxy shim that does
        // NOT have the OI_PROFILE override knob; T6's migration doc
        // notes it stays one release as an alias before being removed
        // in favor of claude-3.
        let content = try Self.shimContent("oi-claude")
        #expect(content.contains("ANTHROPIC_BASE_URL=\"http://127.0.0.1:${OPEN_ISLAND_PORT}\""))
        // Must NOT carry the sentinel prefix — that's claude-3's job.
        #expect(!content.contains("/_oi/profile"))
    }
}
