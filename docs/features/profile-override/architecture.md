# Per-invocation profile override (a.k.a. "card override")

Status: **DRAFT — awaiting approval**
Owner: routing
Created: 2026-05-04
Companion: docs/architecture.md (project-wide), CLAUDE.md (workflow rules)

## Why this exists

Open Island today routes `claude` CLI traffic through a local proxy (127.0.0.1:9710)
whose **active profile is global** (a single string in UserDefaults). Two real pains:

1. **OAuth users get 401.** Anthropic Max/Pro OAuth tokens carry end-to-end client
   identity verification that no proxy can satisfy. The shell-function `claude()`
   in user `~/.zshrc` silently routes every `claude` call through the proxy. If
   the active profile is e.g. DeepSeek and there is no stored DeepSeek key, the
   user's OAuth token is forwarded verbatim to api.deepseek.com → 401.
2. **No multi-terminal parallelism.** Active profile is a single global value.
   Terminal A picks DeepSeek in the GUI; Terminal B cannot simultaneously use
   BuerAI Pro without GUI clicking.

The fix is two layers:

- **Command separation** — `claude` returns to being the official direct-OAuth
  binary (no shell function); `claude-3` (or final name TBD) is the new shim that
  goes through the proxy.
- **Per-invocation override** — the active card stays as the *default*, and any
  one invocation can pick a different profile via env var → URL sentinel → proxy.

## Scope

In scope (this feature):

- Removing `~/.zshrc claude()` shell-function hijack of the official binary
- A new shim `claude-3` (final name TBD) that routes through the proxy
- Per-invocation profile override via `OI_PROFILE=<id> claude-3 …`
- Refactoring profile resolution to be per-request (one resolver call, propagated
  via `LLMProxyRequestContext`)
- Spend / pricing attribution following the resolved profile, not "active at
  pricing time"

Out of scope:

- Codex CLI's own profile override (codex uses `OPENAI_BASE_URL`, separate path)
- Reworking the GUI card grid
- Migration of existing custom profiles (id format unchanged)

## Architecture decision: URL sentinel, not custom HTTP header

Codex review (2026-05-04) flagged that "shim copies env var into HTTP header" is
**unverified** — Claude CLI does not document an env-var-to-header injection
path. The risk: shim writes `X-Open-Island-Profile`, CLI strips or never reads
it, override silently fails.

We avoid the risk by encoding the override in the **URL path prefix** that the
shim writes into `ANTHROPIC_BASE_URL`:

```
ANTHROPIC_BASE_URL=http://127.0.0.1:9710/_oi/profile/buerai-pro
```

The proxy strips `/_oi/profile/<id>` at request entry and treats the rest of the
path (`/v1/messages` etc.) as normal. Pros:

- Works regardless of CLI's header behavior — only depends on URL handling,
  which CLIs always pass through transparently
- Symmetric with existing Anthropic upstream override mechanism
- `ANTHROPIC_BASE_URL` is the only env var the shim needs to set

This is gated on a **spike** (T1) — if for any reason the CLI mangles long base
URLs, we fall back to a header approach with a feature-detection probe.

## Modules touched

| Module | File | Change |
|---|---|---|
| Proxy entry | `Sources/OpenIslandCore/LLMProxyServer.swift` | Strip `/_oi/profile/<id>` prefix; resolve profile once; populate `LLMProxyRequestContext.resolvedProfile` |
| Request context | `Sources/OpenIslandCore/LLMProxyServer.swift` | Add `resolvedProfileId: String`, `profileSelectionSource: .activeDefault | .perRequestOverride` |
| Profile resolver | `Sources/OpenIslandCore/UpstreamProfileStore.swift` | Add `profile(id:) -> UpstreamProfile?` and `resolveProfile(overrideId:) -> ResolvedProfile`; existing `currentActiveProfile()` stays for GUI consumers |
| Body / auth rewrite | `Sources/OpenIslandCore/LLMRequestRewriter.swift` | Accept `resolved: UpstreamProfile` parameter; remove the inline `currentActiveProfile()` calls |
| Pricing | `Sources/OpenIslandCore/LLMPricing.swift` | Read `context.resolvedProfileId`; remove inline `currentActiveProfile()` |
| Spend observer | `Sources/OpenIslandCore/LLMUsageObserver.swift` | Attribute usage to `context.resolvedProfileId` (already takes context — minimal change) |
| Shim assets | `Sources/OpenIslandApp/Resources/bin/` | Add `claude-3` (or final name); update `HookInstallationCoordinator` to install it |
| Localization | `Sources/OpenIslandApp/Resources/*.lproj/Localizable.strings` | Strings for any UI mention of "override" / `OI_PROFILE` (TBD whether we surface it) |

## Data model additions

```swift
// In UpstreamProfileStore (or alongside)
public struct ResolvedProfile: Sendable {
    public let profile: UpstreamProfile
    public let source: Source
    public enum Source { case activeDefault, perRequestOverride }
}

extension UpstreamProfileResolver {
    func resolveProfile(overrideId: String?) throws -> ResolvedProfile
    // throws .unknownOverride(id: String) when overrideId is non-nil and not found
}
```

`LLMProxyRequestContext` gains `resolvedProfileId: String` (stable id, not the
full struct — observers only need attribution).

## Failure modes & responses

| Condition | Response |
|---|---|
| `_oi/profile/<id>` parses but id unknown | **400 Bad Request**, body `{"error":"unknown_open_island_profile","id":"<id>"}`. No silent fallback to active. |
| URL has no sentinel prefix | Treat as legacy path → use active profile (existing behavior, unchanged) |
| Sentinel id resolves to a profile pointing at `api.anthropic.com` with `keychainAccount == nil` | Existing 409 OAuth gate fires (no change) |
| Override id resolves to a profile with no keychain key | Forward upstream as-is; let upstream surface 401 (existing fail-open semantics) |
| Active profile changes between request entry and forward | No effect — resolved once, propagated via context |

## Cleanup work

The shell function in user `~/.zshrc` (lines 86-92) and any global
`export ANTHROPIC_BASE_URL=…` in `.zshenv`, `.zprofile`, or `launchctl getenv`
must be removed. T6 owns this scan; the harness does not modify the user's
dotfiles automatically — it produces a precise checklist.

## Delivery phases

1. **Spike (T1)** — minimal proof that the URL sentinel reaches the proxy
   intact. Time-boxed to one task. If it fails, revisit architecture before
   continuing.
2. **Refactor (T2)** — introduce `ResolvedProfile` + context propagation;
   remove duplicate `currentActiveProfile()` calls. Tests: existing routing
   suite stays green; new test covers active-changing-mid-request idempotency.
3. **Implement override (T3, T4)** — sentinel parser at request entry; 400 on
   unknown id; metric labeled by `profileSelectionSource`.
4. **Shim & cleanup (T5, T6)** — install `claude-3` shim, document migration
   from `oi-claude` (alias kept), produce zshrc cleanup checklist.
5. **Tests & docs (T7, T8, T9)** — round-trip integration test for override
   path; spend tab attribution test; CLAUDE.md / README update.

## Open assumptions

- Anthropic CLI passes through arbitrary path prefix on `ANTHROPIC_BASE_URL`
  unmodified. (Validated by T1 spike.)
- `OI_PROFILE` value is profile **id** (`buerai-pro`), not display name.
- We do not need to surface override source in spend UI v1; the JSON record
  carries it for later UI work.

## Open risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | URL sentinel mangled by CLI | Spike T1 first; fallback to header probe if mangled |
| R2 | Removing zshrc hijack breaks user's existing scripts | Document migration; keep `oi-claude` alias for one release |
| R3 | Refactor regresses concurrent-active test | T2 ships with the existing concurrency test extended; gate before T3 |
| R4 | 400-on-unknown-id surprises users who typo | Error body lists known profile ids; CLI / shim can hint via stderr |

## Naming — decided 2026-05-04 (T9)

- **`claude-3`** is the canonical name for the new proxy-routed shim.
  `claude` and `claude-native` already exist; `claude-3` is the third
  entry in the family (proxy + active + per-call override).
- `oi-claude` stays in the bundle for one release as a deprecation-period
  alias so any user scripts already using it keep working. After that
  release window, T6's migration doc adds a "switch to `claude-3`" step
  and the alias goes away.
