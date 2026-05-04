# profile-override progress log

Cross-session handoff notes. Newest entry on top. Update at the **end** of each
coding session, never mid-task.

---

## 2026-05-04 — T8 docs PASS + feature complete

### What landed

- **CLAUDE.md** — new `## Model routing (LLM proxy)` section before
  `## Important files`. Includes the 3-command table
  (`claude` / `claude-3` / `OI_PROFILE=… claude-3`), key file
  pointers (LLMProxyServer, UpstreamProfileStore, LLMRequestRewriter,
  HookInstallationCoordinator, the 3 shim resources, this feature's
  architecture / migration docs), and the per-request invariant note
  AI agents need: resolve **once** in handleParsedRequest, thread
  ResolvedProfile through context — never call `currentActiveProfile()`
  on the request hot path.
- **README.md** — added `### Model routing` block to the fork
  overview (English audience) plus `### Docs and harness` linking
  to `docs/index.md` and `scripts/harness.sh`. The latter two were
  missing pre-T8 (pre-existing lint debt) and check-docs caught
  them when I added the feature index entries.
- **README.zh-CN.md** — added a full `## 模型路由 / Model routing`
  section after `其他功能` for Chinese audience: 3-command decision
  table, profile registry shape, multi-terminal parallel use case,
  link to migration.md. Also added a `模型路由` row to the 其他功能
  feature table.
- **docs/index.md** — added `## Features` subsection linking the
  3 markdown files in `docs/features/profile-override/`. Also
  linked the pre-existing-but-orphaned
  `docs/usage-freshness-investigation.md` under Investigations.

### Verification

- `bash scripts/check-docs.sh` → `docs check passed`
- `swift test` → **539 / 539** (unchanged from T7 — pure docs round)
- Every link in docs/index.md resolves
- README.md still satisfies both lint requirements (mentions
  `docs/index.md` and `scripts/harness.sh`)

### task.json T8 → passes:true

### Profile-override feature: COMPLETE

```
T1: spike — URL sentinel reaches proxy intact                   ✅
T2: ResolvedProfile + per-request resolution refactor           ✅
T3: parseSentinel + sentinel routing in handleParsedRequest     ✅
T4: 400 with available list on unknown override id              ✅
T5: claude-3 shim + bundled install + install bug fix           ✅
T6: migration.md for the legacy zshrc cleanup                   ✅
T7: cost attribution proven for override flow + fixture fix     ✅
T8: CLAUDE.md / README / docs/index.md command surface           ✅
T9: shim name (claude-3) decision                                ✅
```

All 9 tasks pass. No outstanding deferred work that blocks shipping.

### Ready for atomic commit + push

Suggested commit shape (one PR-sized topic per commit):

1. `feat(routing): add ResolvedProfile + per-request resolution`
   (T2 — UpstreamProfileStore + LLMProxyServer + rewriter +
   pricing + observer + 2 tests)
2. `feat(routing): URL sentinel parser for per-invocation override`
   (T3 + T4 — parseSentinel, override-aware upstream resolution,
   400 on unknown id, all routing tests)
3. `feat(routing): claude-3 shim + fix flat-bundle install lookup`
   (T5 — Resources/bin/claude-3, HookInstallationCoordinator
   bundledShimNames + flat-root lookup, BundledShimsTests)
4. `test(routing): override profile drives cost attribution`
   (T7 — costAttributionUsesResolvedProfileMetadataUnderOverride
   + makeServer observer.profileResolver fixture wiring)
5. `docs(routing): per-invocation override design + migration + index`
   (T1, T6, T8, T9 — architecture.md, migration.md, progress.md,
   task.json, CLAUDE.md, README.md, README.zh-CN.md, docs/index.md)

Or a single mega-commit if preferred — both are defensible.

---

## 2026-05-04 — T7 cost attribution test PASS + test-fixture bug fix

### Scope refinement

The original T7 description proposed asserting against a `byProfile`
rollup in `LLMStatsStore`, but no such field exists today and adding
one is a separate schema change with migration risk on the existing
`llm-stats.json`. Reframed T7 to prove the **user-observable**
invariant: the cost VALUE recorded in `modelCosts` reflects the
override profile's pricing pipeline.

### Test design

`costAttributionUsesResolvedProfileMetadataUnderOverride` sends two
SSE requests with identical usage (input=100, output=42,
cache_read=50, cache_write=0):

| Req | URL | Body model | Body after rewrite | SSE echo | Cost path |
|---|---|---|---|---|---|
| (a) | /v1/messages | claude-opus-4-7 | claude-opus-4-7 | claude-opus-4-7 | static `priceFor` table → ≈$0.001575 |
| (b) | /_oi/profile/deepseek-v4-pro/v1/messages | claude-opus-4-7 | deepseek-v4-pro (T2 modelOverride rewrite) | deepseek-v4-pro | profile.costMetadata path → ≈$0.0000802 (with 75% discount) |

Echoing mock responder reads the request body, extracts the post-
rewrite model field, and parrots it into `message_start` so the
observer's recorded `state.model` matches what the upstream actually
saw.

Asserts:
- `modelCosts["claude-opus-4-7"] > 0`
- `modelCosts["deepseek-v4-pro"] > 0`
- `staticCost > metaCost * 5` (real ratio is ~20×; 5× tolerance
  absorbs future pricing tweaks without rewriting the test)

### Incidental fix

While debugging, found that `LLMProxyServerIntegrationTests.makeServer`
**did not propagate `profileResolver` onto the `LLMUsageObserver`**.
Production wires it in [LLMProxyCoordinator.swift:61](Sources/OpenIslandApp/LLMProxyCoordinator.swift):

```swift
self.usageObserver.profileResolver = profiles
```

The test fixture's helper missed it because no prior test depended on
profile-aware pricing. With the field nil, every request whose
state.model isn't in the static `priceFor` table (i.e. every
DeepSeek / BuerAI request) silently fell to `unpricedTurns += 1` in
the bucket. Restored test/production parity by adding the wire.

### Result

- Tests: **539 / 539** (was 538 + 1 new). T7 test passes in 41ms.
- task.json T7 → passes:true.
- Schema-level byProfile rollup + profileSelectionSource persistence
  captured as a separate follow-up improvement, not blocking the
  override feature shipping. The modelCosts breakdown already
  attributes correctly when profiles use distinct modelOverride
  ids — which is the normal case.
- **Stopped per checkpoint mode.** T8 (CLAUDE.md / README updates)
  cleared.

### Status of profile-override feature

After T7, **server + client + observability** for the per-invocation
override are all production-quality:

```
T1: spike — URL sentinel reaches proxy intact                   ✅
T2: ResolvedProfile + per-request resolution                    ✅
T3: parseSentinel + sentinel routing                            ✅
T4: 400 with available list on unknown override id              ✅
T5: claude-3 shim + bundled install + install bug fix           ✅
T6: migration.md for legacy zshrc cleanup                       ✅
T7: cost attribution proven for override flow                   ✅
T9: shim name (claude-3) decision                                ✅
─────
T8: CLAUDE.md / README updates                          (last  pending)
```

Only T8 remains — pure documentation. Then the feature is ready to
commit + push.

---

## 2026-05-04 — T6 migration doc PASS

- Wrote [docs/features/profile-override/migration.md](migration.md).
  Self-contained, read-only guidance — the architecture invariant
  that the harness does NOT touch the user's dotfiles is preserved.
- Doc is structured for two audiences:
  1. **Existing user with the legacy `~/.zshrc claude()` function**:
     5-step migration with copy-paste commands, a verbatim rollback
     recipe, troubleshooting for the most likely surprises (401
     after migration, 400 with unknown_open_island_profile,
     `claude-3` not found).
  2. **New user / fresh reader**: Decision matrix (`claude` vs
     `claude-3` vs `OI_PROFILE=… claude-3`) so the command surface
     can be picked up without reading the migration steps.
- Sweep coverage: ~/.zshrc + ~/.zshenv + ~/.zprofile + ~/.profile +
  ~/.bashrc + ~/.bash_profile + `launchctl getenv` + NSGlobalDomain.
  Catches all the places a stray `ANTHROPIC_BASE_URL` export could
  re-hijack the official `claude` after the function is removed.
- No code changes, no tests required (doc-only task).
- task.json T6 → passes:true.
- **Stopped per checkpoint mode.** T7 (spend-attribution test) and
  T8 (CLAUDE.md / README updates) cleared.

### Status of profile-override feature

After T6, the **user-facing migration story is complete**:

```
T1: spike validates URL sentinel approach              ✅
T2: ResolvedProfile + per-request resolution refactor  ✅
T3: parseSentinel + sentinel routing in proxy entry    ✅
T4: 400 with available list on unknown override id     ✅
T5: claude-3 shim + bundled install + install bug fix  ✅
T6: migration.md for the legacy zshrc cleanup          ✅
T9: shim name decision (claude-3)                       ✅
─────
T7: spend / pricing attribution test (override profile)  pending
T8: CLAUDE.md / README updates                            pending
```

Both remaining tasks are short and parallel-safe (no dependencies
between them). T7 can land before T8 or after — task.json declared
T8 depends on T5 + T6, both of which are now done.

---

## 2026-05-04 — T5 claude-3 shim PASS + incidental install-bug fix

### What shipped

- New file `Sources/OpenIslandApp/Resources/bin/claude-3` (zsh,
  mode 0755). When `OI_PROFILE` is set, builds
  `ANTHROPIC_BASE_URL=http://127.0.0.1:${OPEN_ISLAND_PORT:-9710}/_oi/profile/${OI_PROFILE}`;
  otherwise a bare proxy URL. Final `exec env ANTHROPIC_BASE_URL=… claude "$@"`.
- New file `Tests/OpenIslandAppTests/BundledShimsTests.swift` —
  6 tests covering bundle presence, source-of-truth drift detection,
  and per-shim content invariants for all three shims.

### Incidental fix uncovered during T5

Verifying the install path turned up a **pre-existing latent bug** in
`ensureShimsInstalled`: it called
`Bundle.appResources.urls(forResourcesWithExtension: nil, subdirectory: "bin")`,
but SPM's `.process("Resources")` rule **flattens** the source
`Resources/bin/` subtree into the bundle root at build time. The
subdirectory query therefore returned an empty array on every run
and the function silently no-op'd. The old shims that the user had
in `~/.open-island/bin/` were leftovers from an earlier code version
that used a different layout — nothing was being refreshed.

T5 caught this because `claude-3` was never going to install, even
on a brand-new build. Fix:

- Replaced the directory-enumeration with an explicit
  `nonisolated static let bundledShimNames: [String] = [...]`
  source-of-truth list.
- Flat-root lookup via
  `Bundle.appResources.url(forResource: name, withExtension: nil)`
  matches how the bundle actually lays files out.
- New test `installerSourceOfTruthMatchesBundle` catches future drift
  in either direction (listed-but-missing or present-but-unlisted).

### Verification

- Tests: **538 / 538** (was 532 + 6 new). BundledShimsTests → **6 / 6**.
- Manual smoke: rebuilt + relaunched dev app via launcher; after
  ~5s `~/.open-island/bin/claude-3` appears (1764B, fresh mtime,
  executable). Live `curl http://127.0.0.1:9710/_oi/profile/deepseek-v4-pro/healthz`
  → 200 ok, proves the running app's proxy receives the sentinel
  path verbatim and `parseSentinel(path:)` correctly strips it
  before the healthz short-circuit. T3 invariant validated
  end-to-end on the running app, not just unit-level.

### Status of profile-override feature

After T5, the **end-to-end happy path works on the running app**:

```
zsh: OI_PROFILE=deepseek-v4-pro claude-3 ...
  → ANTHROPIC_BASE_URL=http://127.0.0.1:9710/_oi/profile/deepseek-v4-pro
  → proxy parseSentinel → overrideId=deepseek-v4-pro, requestPath=/v1/messages
  → resolveProfile(overrideId:) → ResolvedProfile(deepseek-v4-pro, .perRequestOverride)
  → upstreamForAnthropic → api.deepseek.com/anthropic
  → rewriteAuthorizationIfNeeded uses deepseek keychain key
  → rewriteModelFieldIfNeeded → claude-opus-4-7 → deepseek-v4-pro
  → forward to https://api.deepseek.com/anthropic/v1/messages
  → spend attribution recorded under deepseek-v4-pro (override source)
```

GUI active is unchanged through any of this — terminal A can keep
its anthropic-native default while terminal B scripts deepseek calls.

### What remains

T6 (migration.md for the user's dotfile cleanup), T7 (spend
attribution test), T8 (CLAUDE.md / README docs). All client-side
documentation, no further server work.

### Stopped per checkpoint mode. T6 cleared.

---

## 2026-05-04 — T9 naming decision: `claude-3`

- User picked **`claude-3`** as the canonical shim name. No code change
  this round — purely a decision that unblocks T5's file path.
- Rationale: pairs visually with `claude` / `claude-native`; the "3"
  is a generation marker for the Open Island shim family (not the
  Claude model version), so it won't need renaming when Anthropic
  bumps the model major version again.
- Rejected alternatives recorded in `task.json` T9 notes (`oic`,
  `claude-oi`, `claudex`).
- `architecture.md` "Naming TBD" section replaced with the locked-in
  decision and the deprecation plan for `oi-claude` (stays one
  release as alias, removed after that with T6's migration doc).
- task.json T9 → passes:true.
- T5 now has a concrete file path to create:
  `Sources/OpenIslandApp/Resources/bin/claude-3` (chmod 0755).

---

## 2026-05-04 — T4 unknown-override 400 PASS

- Added `availableProfileIds()` to `UpstreamProfileResolver` protocol
  (default impl returns `[active.id]` for test fakes; concrete
  `UpstreamProfileStore` overrides with `allProfiles.map(\.id).sorted()`).
- Replaced T3's `try?` shortcut in `handleParsedRequest` with an
  explicit `do/catch`:
  - `UpstreamProfileResolverError.unknownOverride(let id)` →
    `respondLocally(400, body: Self.makeUnknownOverrideBody(id, available))`
  - Any other thrown error (defensive) → `respondLocally(500, …)`
- Added `LLMProxyServer.makeUnknownOverrideBody(id:available:)` —
  uses `JSONSerialization` to build the body so dynamic `id` and
  `available` need no manual escaping. Envelope shape:
  ```json
  {"type":"error","error":{
    "type":"unknown_open_island_profile",
    "id":"<typo>",
    "available":["..."],
    "message":"OI_PROFILE / URL sentinel referenced a profile id that is not registered. ..."
  }}
  ```
  Matches the existing 409 OAuth-blocked envelope so client error
  pipelines stay uniform.
- Added one integration test
  (`unknownOverrideIdReturns400WithAvailableList`) that verifies:
  - HTTP status 400
  - Body parses as JSON, `error.type == unknown_open_island_profile`
  - `error.id` echoes the typo
  - `error.available` contains the canonical builtin ids and is sorted
  - Upstream is NOT contacted (waited 100ms post-response, captures
    stay empty)
- Added `UnknownOverrideUpstreamFlag` helper class.
- Test totals: **532 / 532** (was 531 + 1 new). T4-filtered suites
  → **60 / 60** clean.
- task.json T4 → passes:true.
- **Stopped per checkpoint mode.** T5 (claude-3 shim emitting the
  sentinel from `$OI_PROFILE`) cleared.

### Status of the profile-override feature half-way mark

After T4, the **server side is feature-complete for per-invocation
override**:
- Parser strips `/_oi/profile/<id>/`
- Resolver throws on unknown id, proxy 400s with available list
- Resolved profile threads through upstream URL choice, OAuth gate,
  model rewrite, auth rewrite, pricing
- `currentActiveProfile()` is called exactly once per request, at
  entry, and only for the `.activeDefault` case

Remaining tasks (T5–T9) are about the **client-side ergonomics**:
shipping the `claude-3` shim that emits the sentinel from
`$OI_PROFILE`, writing the dotfile cleanup checklist for users to
remove the legacy zshrc hijack, deciding the final shim name, and
documenting the new command surface.

---

## 2026-05-04 — T3 sentinel parser PASS

- Added `LLMProxyServer.parseSentinel(path:)` near the URL-handling
  utilities. Splits `/_oi/profile/<id>/<rest>` into
  `(overrideId, requestPath)`; absent / malformed / look-alike-prefix
  paths return `(nil, original)`.
- Reordered `handleParsedRequest`:
  1. Parse sentinel → cleaned `requestPath`
  2. Healthz check on `requestPath`
  3. Resolve profile with `overrideId` (`try?` swallow for now —
     T4 will replace with explicit catch + 400)
  4. Route on `requestPath`
  5. Determine upstream from resolved profile (renamed helper:
     `resolvedAnthropicUpstream()` → `upstreamForAnthropic(resolved:)`)
  6. OAuth gate using resolved profile (not active)
  7. Apply rewrites with resolved.profile
  8. Build context with `path: requestPath` (cleaned), forward
- The two functions that previously read `currentActiveProfile()`
  inline (`resolvedAnthropicUpstream`, `isAnthropicPassthroughBlocked`)
  now take `resolved: ResolvedProfile?` parameters. After this
  change, **the only call to `currentActiveProfile()` on the proxy
  hot path is the `try?` resolveProfile call at request entry** —
  exactly what codex's review pinned as the goal.
- Added 4 new tests:
  - `sentinelParser` — 6 inline cases (happy path, no sentinel,
    no further segments, empty id, look-alike prefix, healthz with
    sentinel prefix)
  - `sentinelOverrideRoutesToOverrideProfileBaseURL` — T3 (a):
    sentinel id = deepseek-v4-pro, active = anthropic-native →
    forward host == api.deepseek.com, upstream sees path
    `/anthropic/v1/messages` (sentinel stripped), context source ==
    `.perRequestOverride`
  - `sentinelAbsentFallsBackToActiveDefault` — T3 (b)
  - `sentinelWinsWhenActiveAndOverrideDisagree` — T3 (c)
- Test totals: **531 / 531** (was 527 + 4 new). T3-filtered suites →
  **59 / 59** clean.
- task.json T3 → passes:true with full files-changed manifest +
  proven invariants list.
- **Stopped per checkpoint mode.** T4 (400 on unknown override id)
  cleared.

### Deferred to T4

Today an invalid override id (e.g. `/_oi/profile/typo/...`) silently
falls through to `resolved == nil` and the request forwards with no
rewrite — almost certainly producing a confusing 401 from upstream
because the request bypassed the resolver entirely. T4 turns this
into a 400 with `{"error":"unknown_open_island_profile","id":"<typo>",
"available":[...]}` so users see the real problem at the proxy edge.

---

## 2026-05-04 — T2 refactor PASS

- Added `ProfileSelectionSource`, `ResolvedProfile`, `UpstreamProfileResolverError`
  in `UpstreamProfileStore.swift`.
- Extended `UpstreamProfileResolver` protocol with `profile(id:)` and
  `resolveProfile(overrideId:)`. Default implementations on the protocol so
  test fakes (`StubResolver`, `BlockedAnthropicNativeResolver`,
  `FakeAnthropicNativeResolver`) didn't need any change.
- `LLMProxyRequestContext` gained `resolvedProfileId: String?` and
  `profileSelectionSource: ProfileSelectionSource?`. Default-`nil` so all
  existing call sites still compile.
- `LLMProxyServer.handleParsedRequest` now resolves the profile once via
  `profileResolver?.resolveProfile(overrideId: nil)` and threads
  `resolved.profile` into both `rewriteModelFieldIfNeeded(_:path:profile:)`
  and `rewriteAuthorizationIfNeeded(_:profile:credentialsStore:)` via the
  new direct-profile overloads. `forward()` signature gained `resolved:
  ResolvedProfile?`.
- `LLMRequestRewriter` and `LLMPricing` got new direct-profile overloads;
  the resolver-based versions stay as thin compat shims (so existing
  rewriter / pricing tests still cover the expected behavior unchanged).
- `LLMUsageObserver` reads `context.resolvedProfileId` and looks up the
  profile via `profileResolver.profile(id:)` for cost attribution; falls
  back to `currentActiveProfile()` only when the context lacks an id
  (no-resolver legacy path).
- Added 2 tests:
  - `LLMRequestRewriterModelFieldTests.directProfileVariantRewritesWithoutResolverIndirection`
    — exercises new direct-profile model rewrite.
  - `LLMProxyActiveProfileRoutingTests.resolvedProfileIdReflectsActiveAtRequestEntry`
    — sends Request A under anthropic-native, flips active to deepseek,
    sends Request B; observer captures both contexts; A's
    `resolvedProfileId` pinned to anthropic-native, B's to deepseek-v4-pro.
    Proves entry-time resolution invariant the codex review flagged.
- Hit a Swift 6 strict-concurrency snag: `NSLock.unlock()` is unavailable
  from async contexts. Fixed by wrapping lock interactions in synchronous
  helpers (`append(_:)`, `read()`) on `ContextCapturingObserver` and
  having the async overrides call them.
- Test totals: **527 / 527** (was 525 + 2 new). T2-filtered suites
  (`LLMRequestRewriter`, `LLMProxyActiveProfileRoutingTests`,
  `UpstreamProfile`) → **45 / 45** clean.
- task.json T2 → passes:true with full files-changed manifest.
- **Stopped per checkpoint mode.** T3 (sentinel parser at proxy entry)
  cleared to start.

### Architectural payoff captured this round

After this refactor, the **only** place `currentActiveProfile()` is called on
the request hot path is in `LLMProxyServer.handleParsedRequest`'s single
`resolveProfile(overrideId: nil)` call (and in the legacy compat shims of
the rewriter / pricing, which are used only by older test wiring, not by
the proxy). T3 will replace that one call with a parser → `overrideId`
plumbing, and the per-request override propagation falls into place
without further structural change.

---

## 2026-05-04 — T1 spike PASS

- Approval recorded (interactive, T1 only).
- Inserted temporary `Self.logger.info("[OI-T1-SPIKE] path=… method=…")` at the
  top of `LLMProxyServer.handleParsedRequest`.
- Rebuilt + relaunched `Open Island Dev.app` via `scripts/launch-dev-app.sh
  --skip-setup` (PID 85749).
- Probed:
  ```sh
  curl -X POST 'http://127.0.0.1:9710/_oi/profile/spike-test/v1/messages' \
       -H 'content-type: application/json' \
       -H 'authorization: Bearer fake' --data '{}'
  ```
- Log captured:
  ```
  [app.openisland:LLMProxy] [OI-T1-SPIKE] path=/_oi/profile/spike-test/v1/messages method=POST
  ```
  → **Sentinel preserved verbatim from URLSession-equivalent client through
  to proxy `head.path`.** URL-sentinel hypothesis validated.
- Side observation worth flagging for T3: with no sentinel parser yet, the
  request was misrouted to `api2.tabcode.cc/openai/plus/_oi/profile/...`
  (returned upstream 404). That confirms the router currently treats
  unprefixed paths as openai when the active profile is `deepseek-v4-pro` and
  there's no "/v1/messages" prefix matched. T3 will strip the sentinel before
  routing decisions, making this a non-issue.
- Probe reverted; `swift build --target OpenIslandCore` clean (0.41s).
  `grep "OI-T1-SPIKE" Sources/OpenIslandCore/LLMProxyServer.swift` → 0 hits.
- task.json T1 → passes:true with full notes block.
- **Stopped per checkpoint mode.** T2 cleared; awaiting next explicit prompt.

---

## 2026-05-04 (planning) — Bootstrap

- Drafted [architecture.md](architecture.md) and [task.json](task.json) per
  no-slacking harness protocol.
- Codex review (`codex consult` thread `019df150-1e8e-77f2-a5e0-db623c6325b5`)
  surfaced 3 risks that shaped the design:
  1. Custom HTTP header from a shim is **unverified** — pivoted to URL sentinel
     approach (`/_oi/profile/<id>`).
  2. `currentActiveProfile()` is read in 3 places (`LLMProxyServer:389`,
     `LLMRequestRewriter:181`, `LLMPricing:218`) — refactor to per-request
     resolved profile.
  3. Header naming should be `X-Open-Island-*` (matches existing
     `X-Open-Island-Upstream`), but with the sentinel approach this is moot.
- Confirmed companion commits already on this branch:
  - `0fd6303` — install `claude-native` + `oi-claude` shims
  - `5325cf3` — 409 OAuth gate at proxy entry
  - 6 uncommitted files from BuerAI canonicalization round (separate scope)
- **Status: awaiting `/approve` slash-command.** No implementation started.

### Init / regression baseline

- `swift build -c debug --product OpenIslandApp` clean (incremental ~2.5s)
- Latest full `swift test` run (pre-feature): **525 / 525 green**, 62 suites
- Dev launcher proven working: `Open Island Dev.app` PID 22127

### Notes for the agent that picks this up after approval

- Honor T1 first. If T1 spike fails, **stop and revisit** — the URL sentinel
  approach is the load-bearing assumption.
- Do not modify the user's `~/.zshrc` from any task. T6 is documentation only.
- Do not rename `oi-claude` until T9 picks the canonical name. Keep the old
  name as an alias for at least one release.
