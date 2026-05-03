# Claude Usage Freshness — Investigation Closed

**Status:** Closed (do not re-investigate without explicit product ask)
**Decision date:** 2026-05-03
**Decision:** Accept the staleness UI as the upper bound under Claude Code's
public surface. Do not add hidden polling or synthetic Claude Code prompts.

## TL;DR for the next worker

`rate_limits.five_hour.used_percentage` and `rate_limits.seven_day.used_percentage`
are exposed by Claude Code only on **interactive statusline stdin**. None of:
- `claude -p`
- `--output-format=stream-json --include-hook-events`
- hook event payloads
- debug-file (`--debug-file`)
- transcript JSONL
- local cache files

contains the equivalent fields. Faking `TERM_PROGRAM=iTerm.app` +
`ITERM_SESSION_ID=...` + a real `expect`-managed PTY + a real prompt
turn does **not** trigger the statusline either. Claude Code's terminal
identity check is deeper than env vars.

Therefore:
- **Don't** add hidden background polling that spawns `claude -p` (won't
  refresh the cache; was confirmed empirically — see "Rejected paths").
- **Don't** maintain a hidden interactive PTY claude session to harvest
  statusline output (burns Anthropic quota, alters the very metric being
  observed, fragile to Claude Code updates).
- **Do** trust the existing pipeline: statusline → `/tmp/open-island-rl.json`
  → `HookInstallationCoordinator` 5s poll → SwiftUI.
- **Do** keep the stale-percentage opacity decay and "Nh ago" badge
  (see [`IslandPanelView.usageWindowView`](../Sources/OpenIslandApp/Views/IslandPanelView.swift))
  visible to the user.

If a future product spec genuinely requires real-time parity with the
Claude Desktop Settings → Usage page, that is a separate two-stage
project — see "Future: real-time parity" below.

## Architecture (current pipeline)

```
Claude Code interactive UI                   (only writer)
  └── /v1/messages response carries .rate_limits
       └── Claude Code injects it into statusline stdin JSON
            └── ~/.open-island/bin/open-island-statusline (bash)
                 └── /tmp/open-island-rl.json
                      └── ClaudeUsageLoader (5 s poll, see HookInstallationCoordinator)
                           └── AppModel.claudeUsageSnapshot
                                └── IslandPanelView usage row
```

## Rejected paths (with empirical evidence)

| Path | Hypothesis | Result |
|------|-----------|--------|
| `claude -p "ping"` | print mode triggers statusline | `/tmp/open-island-rl.json` mtime unchanged after spawn |
| `claude -p "/usage"` | slash command exposes usage | mtime unchanged; stdout is one-liner with no rate_limits |
| `claude -p ... --output-format=stream-json --include-hook-events --verbose` | stream-json dumps everything | `rate_limit_info` field exists but only contains `{status, resetsAt, rateLimitType}` — **no `used_percentage`** |
| `expect -c 'spawn claude; send "ok\r"; sleep 30; send "/exit\r"'` | PTY-wrapped interactive session triggers statusline | trace log 0 bytes |
| Same as above + `TERM_PROGRAM=iTerm.app TERM_PROGRAM_VERSION=3.5.0 ITERM_SESSION_ID=w0t0p0:FAKE COLORTERM=truecolor FORCE_HYPERLINK=1` | env-var fakery clears Claude Code's terminal check | trace log 0 bytes |
| `statusLine.refreshInterval` in settings.json | bumping interval triggers a fresh API call | re-runs the script; does not pull from Anthropic |

Conclusion: Claude Code's statusline is gated by something deeper than
`TERM_PROGRAM` (likely TTY device class + TUI lifecycle state). It cannot
be coaxed from outside a real Terminal/iTerm/Ghostty/etc. session.

## What ships today

1. **Cache pipeline** (already existed): 5s poll of `/tmp/open-island-rl.json`
2. **Staleness opacity** ([`634b16a`](https://github.com/8676311081/open-island/commit/634b16a)):
   - <5 min: 100% opacity (fresh)
   - 5–30 min: 60% opacity (aging)
   - >30 min: 35% opacity (stale)
3. **"Nh ago" badge** in `.full` layout once cache exceeds 5 min
4. **Tooltip** ([`3c118d0`](https://github.com/8676311081/open-island/commit/3c118d0)):
   `Cached Nh ago. Claude usage updates only when Claude Code's
   interactive statusline receives fresh rate_limits. Claude Desktop
   and web usage may already be newer.`

## Future: real-time parity (only if explicitly scoped)

The Claude Desktop Settings → Usage page hits a private Anthropic
account-usage endpoint. Possible to mirror, but every step is a
maintenance liability. Required guardrails before any code lands:

1. mitmproxy capture of Claude Desktop's request (endpoint, auth header,
   response schema) — manual, requires user cooperation.
2. OAuth token sourcing from macOS Keychain (service `Claude Code`).
3. SwiftPM Keychain entitlement work.
4. **Feature flag, opt-in, fail-closed**: when the private endpoint or
   schema changes (it will), silently fall back to the current statusline
   pipeline rather than blanking the UI or showing wrong numbers.
5. Document this code path's drift expectations in
   [`PRIVACY_POLICY.md`](../PRIVACY_POLICY.md) (it adds an outbound
   request that the current "no telemetry" claim does not cover).

This is a multi-day project, not a 1-commit feature. Don't start it as
a side errand to a usage-related PR.
