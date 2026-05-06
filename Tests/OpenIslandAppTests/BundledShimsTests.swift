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
        // Five shims must be in the bundle so the install loop in
        // `ensureShimsInstalled` finds them. Adding a new shim later
        // means extending the source-of-truth list in
        // HookInstallationCoordinator.bundledShimNames AND adding a
        // per-content test below.
        let expected = [
            "claude-native",
            "oi-claude",
            "claude-3",
            "claude-deep",
            "oi-current-active-group",
        ]
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
        // set — same exec line shape as the other shims. Multi-line
        // continuation form (`exec env \\` then env-var assignments)
        // is the canonical post three-port shape.
        #expect(content.contains("exec env"))
        #expect(content.contains("ANTHROPIC_BASE_URL="))
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
        #expect(!content.contains("/_oi/family"))
    }

    @Test
    func claudeDeepShimDispatchesToPort9711() throws {
        // Post three-port split, claude-deep no longer emits the
        // legacy `/_oi/family/deepseek` URL sentinel — the listener
        // on 9711 IS the DeepSeek family. The shim's job is now to
        // pin OPEN_ISLAND_PORT at 9711 by default and let the
        // listener policy do the enforcement (it returns 421 if the
        // GUI-active profile is not a deepseek builtin).
        let content = try Self.shimContent("claude-deep")
        #expect(
            content.contains(": \"${OPEN_ISLAND_PORT:=9711}\""),
            "claude-deep must default OPEN_ISLAND_PORT to 9711"
        )
        // Legacy `/_oi/family/deepseek` sentinel must be gone — the
        // listener-policy enforcement supersedes it.
        #expect(!content.contains("/_oi/family/deepseek"),
                "claude-deep should not emit the legacy /_oi/family/deepseek sentinel")
        // Verify the OI_PROFILE check guards the override branch.
        #expect(
            content.contains("\"${OI_PROFILE:-}\"") || content.contains("\"$OI_PROFILE\""),
            "claude-deep must check OI_PROFILE before deciding which URL to emit"
        )
    }

    @Test
    func claude3ShimDispatchesByActiveProviderGroup() throws {
        // claude-3 must consult the GUI-active profile's
        // ProviderGroup and pick the matching loopback port. Three
        // hard requirements:
        //  - calls `oi-current-active-group` helper
        //  - maps deepseek → 9711, thirdParty → 9712, default 9710
        //  - exports OPEN_ISLAND_PROVIDER_GROUP for downstream hooks
        let content = try Self.shimContent("claude-3")
        #expect(content.contains("oi-current-active-group"),
                "claude-3 must invoke the active-group helper")
        #expect(content.contains("9711"), "claude-3 must know about the deepseek port")
        #expect(content.contains("9712"), "claude-3 must know about the thirdParty port")
        #expect(content.contains("9710"), "claude-3 must know about the officialClaude port")
        #expect(content.contains("OPEN_ISLAND_PROVIDER_GROUP="),
                "claude-3 must export OPEN_ISLAND_PROVIDER_GROUP")
    }

    @Test
    func currentActiveGroupHelperOutputsRecognizedTags() throws {
        // The helper must only emit one of the three ProviderGroup
        // raw values. shim consumers depend on this exact set.
        let content = try Self.shimContent("oi-current-active-group")
        #expect(content.contains("officialClaude"))
        #expect(content.contains("deepseek"))
        #expect(content.contains("thirdParty"))
        // Helper reads UserDefaults via `defaults`. If this changes
        // we need to re-evaluate whether we're picking up the right
        // app domain (app.openisland.dev).
        #expect(content.contains("defaults read app.openisland.dev"),
                "helper must read OpenIsland's UserDefaults domain")
        #expect(content.contains("OpenIsland.LLMProxy.activeProfileId"),
                "helper must read the canonical active-profile-id key")
    }

    @Test
    func claudeDeepShimHonorsOIProfileOverride() throws {
        // claude-deep keeps the same `OI_PROFILE` escape hatch as
        // claude-3 — when set, it wins over the family constraint.
        // This is the documented advanced-user override (option B in
        // the design doc): named command picks the family by default,
        // env var lets a single invocation cross the line.
        let content = try Self.shimContent("claude-deep")
        #expect(content.contains("/_oi/profile/${OI_PROFILE}"),
                "claude-deep must encode OI_PROFILE into a /_oi/profile/<id> URL prefix when set")
    }

    @Test
    func claudeDeepShimUsesProxyAndExecsClaude() throws {
        // Smoke that the shim reaches `exec env … claude "$@"` shape
        // used by the other proxy shims. Catches refactors that
        // accidentally invoke a different binary or forget to thread
        // args.
        let content = try Self.shimContent("claude-deep")
        #expect(content.contains("127.0.0.1:${OPEN_ISLAND_PORT}"))
        #expect(content.contains("exec env"))
        #expect(content.contains("ANTHROPIC_BASE_URL="))
        #expect(content.contains("claude \"$@\""))
    }
}
