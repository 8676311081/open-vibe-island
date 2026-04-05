# Session State Management Refactoring Plan

## 1. Problem Statement

The current session state management is overly complex. A 3-state attachment model (`attached`/`stale`/`detached`) with 6+ reconciliation passes, AppleScript snapshots driving visibility, multi-pass matching, 15-minute grace windows, synthetic session creation, and CWD-based fallback matching. Every new terminal (e.g., cmux) requires patches across multiple code paths.

The reference product (Vibe Island) achieves the same UX with a simpler model:
- Only maintains active sessions
- Simple status: `processing` / `waiting_for_input`
- Process exits → session disappears
- No attachment state machine

**Core principle: sessions should map 1:1 to the user's terminal sessions. Claude starts → session appears. Claude exits → session disappears. No grace windows, no lingering.**

## 2. Dual-Signal Model: Hooks + Process Discovery

Session lifecycle is driven by two complementary signal sources:

### Hooks (primary, fast, rich)
- **SessionStart** → create session immediately with full metadata (prompt, terminal info, etc.)
- **PreToolUse / PostToolUse / Notification / etc.** → update session state
- **SessionEnd** → mark session as ended, remove from display immediately

### Process Discovery (secondary, polling every 3s, fallback)
- Discovers running agent processes via `ps`/`lsof`
- Creates sessions for processes that have no hook-originated session (e.g., hooks not configured)
- Removes sessions whose process is no longer found

The two sources complement each other:
| Scenario | Hooks | Process Discovery |
|---|---|---|
| Normal startup | SessionStart fires immediately | Confirms process exists within 3s |
| Normal exit | SessionEnd fires immediately | Confirms process gone within 3s |
| Hooks not configured | Nothing | Creates session from process within 3s |
| Process killed (no SessionEnd) | Nothing | Detects process gone within 3s |
| Brief process detection gap | Hook activity keeps session alive | Resumes seeing process next cycle |

### Visibility Rule

A session is visible if and only if:
1. Process is alive (confirmed by latest process discovery), OR
2. Phase requires user attention (`waitingForApproval` / `waitingForAnswer`), OR
3. Session received a hook event within the last polling cycle (3s) — covers the brief gap between SessionStart hook and first process discovery

A session is removed when:
- Process is not found AND no recent hook activity AND phase doesn't require attention

**No grace windows.** No 60-second delays. No 15-minute stale periods. The session disappears within one polling cycle (~3 seconds) of the process exiting, just like the reference product.

## 3. New State Model

### Remove
- `SessionAttachmentState` enum (attached/stale/detached) — **delete entirely**
- `SessionOrigin` enum — replace with `isDemoSession` computed property
- All grace window constants (`liveGraceWindow`, `staleGraceWindow`, `inactiveClaudeMatchWindow`)

### Add to `AgentSession`
```swift
var isProcessAlive: Bool = false       // updated by process discovery every 3s
var lastHookActivityAt: Date?          // updated on every hook event
```

### Visibility (replaces `isAttachedToTerminal`)
```swift
var isVisibleInIsland: Bool {
    if isDemoSession { return true }
    if phase.requiresAttention { return true }
    if isProcessAlive { return true }
    if let lastHook = lastHookActivityAt,
       Date.now.timeIntervalSince(lastHook) < 5 { return true }
    return false
}
```

## 4. What Changes in Each File

### Delete entirely
- `Sources/OpenIslandApp/TerminalSessionAttachmentProbe.swift` (1170 lines)
- `Sources/OpenIslandCore/ClaudeSessionRegistry.swift` (159 lines) — or gut to ~30 lines for pending-interaction persistence only

### New file
- `Sources/OpenIslandApp/TerminalJumpTargetResolver.swift` (~250 lines) — extracted from probe, handles jump target precision via AppleScript snapshots. **Only affects jump accuracy, never visibility.**

### `Sources/OpenIslandCore/AgentSession.swift`
- Remove: `SessionAttachmentState`, `SessionOrigin`, `attachmentState`, `origin`, `isAttachedToTerminal`
- Add: `isProcessAlive`, `lastHookActivityAt`, `isVisibleInIsland` computed property

### `Sources/OpenIslandCore/SessionState.swift`
- Remove: `reconcileAttachmentStates()`, `reconcileJumpTargets()`, attachment-based counts
- Add: `markProcessAlive()`, `removeSession()`, `removeInvisibleSessions()`

### `Sources/OpenIslandApp/AppModel.swift` (~450 lines removed)
- Remove: synthetic session infrastructure, `adoptProcessTTYsForClaudeSessions`, `sanitizeCrossToolGhosttyJumpTargets`, `mergeAttachmentState`, `liveAttachmentKey`, complex `displayPriority`
- Rewrite `reconcileSessionAttachments()`: discover processes → mark alive/dead → remove invisible → update jump targets
- Rewrite `computeSessionBuckets()`: filter by `isVisibleInIsland`, sort by attention > running > updatedAt

### `Sources/OpenIslandCore/DemoBridgeServer.swift`
- Keep as-is. Add `lastHookActivityAt = Date.now` when processing any hook event.

## 5. Migration Phases

### Phase 1: Add new fields in parallel (LOW RISK)
- Add `isProcessAlive` and `lastHookActivityAt` to `AgentSession`
- Populate from process discovery and hook events
- Log discrepancies vs old attachment model
- Write tests for new liveness model
- **No behavior change**

### Phase 2: Extract `TerminalJumpTargetResolver` (LOW RISK)
- Move AppleScript snapshot + jump target matching logic to new focused type
- Old probe stays unchanged
- Verify jump targets match
- **No behavior change**

### Phase 3: Switch visibility model (MEDIUM RISK)
- `computeSessionBuckets` uses `isVisibleInIsland` instead of `isAttachedToTerminal`
- Stop calling old attachment probe for visibility
- Keep calling `TerminalJumpTargetResolver` for jump precision
- **Behavior change: sessions disappear faster after exit**

### Phase 4: Session removal + cleanup (MEDIUM RISK)
- Implement `removeInvisibleSessions()` — actually remove dead sessions from state
- Remove synthetic session creation — process discovery creates sessions directly
- Remove `adoptProcessTTYsForClaudeSessions`
- **Behavior change: session count stays small**

### Phase 5: Delete dead code (LOW RISK)
- Delete `TerminalSessionAttachmentProbe.swift`
- Delete `ClaudeSessionRegistry.swift` (or gut)
- Remove `SessionAttachmentState`, `SessionOrigin` enums
- Clean up tests
- **~1000 lines removed**

## 6. Verification Plan

### Key Scenarios
1. Start Claude → session appears within 3s
2. Exit Claude → session disappears within 3s
3. Jump to Ghostty/Terminal.app/cmux works
4. Permission approval flow works end-to-end
5. Question answering flow works
6. Notification fires on completion
7. Subagent shows as parent metadata, not separate session
8. Multiple terminals simultaneously
9. App restart → sessions reappear within 3s
10. Codex sessions work
11. Demo mode unaffected

### Before/After Comparison
Phase 1-2: log old `attached` set vs new `isProcessAlive` set per cycle. All discrepancies must be explained as intentional simplification or bugs.

### Risk Areas
1. **Jump precision regression** — mitigated by reusing existing matching logic in resolver
2. **Completed session visibility change** — intentional, matches reference product
3. **Restart metadata loss** — acceptable since process discovery + hooks rebuild state within seconds

## 7. Impact Summary

| Metric | Before | After |
|---|---|---|
| TerminalSessionAttachmentProbe | 1170 lines | 0 (deleted) |
| TerminalJumpTargetResolver (new) | 0 | ~250 lines |
| AppModel session management | ~750 lines | ~300 lines |
| Attachment state values | 3 | 0 (deleted) |
| Grace windows | 3 (120s, 15min, 120s) | 0 |
| Reconciliation passes per cycle | 6+ | 2 |
| Persisted sessions | All (29) | Only pending-interaction |
| **Net lines removed** | | **~1000** |
