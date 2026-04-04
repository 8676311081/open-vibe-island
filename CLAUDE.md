# CLAUDE.md

## What is this project?

Open Island is a native macOS companion app for AI coding agents. It sits in the notch/top-bar area and monitors local agent sessions, surfaces permission requests, answers questions, and provides "jump back" to the correct terminal context. Local-first, no server dependency.

## References

- **Target product**: https://vibeisland.app/ — the commercial product we are building toward feature parity with
- **Reference OSS repo**: https://github.com/farouqaldori/claude-island — open-source implementation we can study for design patterns and ideas

## Architecture

Four targets in one Swift package (`OpenIsland`):

1. **OpenIslandApp** — SwiftUI + AppKit shell. Menu bar extra, overlay panel (notch/top-bar), and control center window. Entry point: `OpenIslandApp.swift` with `AppModel` as the central `@Observable` state owner.
2. **OpenIslandCore** — Shared library. Models (`AgentSession`, `AgentEvent`, `SessionState`), bridge transport (Unix socket IPC with JSON line protocol), hook models/installers for both Codex and Claude Code, transcript discovery, session persistence/registry.
3. **OpenIslandHooks** — Lightweight CLI executable invoked by agent hooks. Reads hook payload from stdin, forwards to app bridge via Unix socket, writes blocking JSON to stdout only when island denies a `PreToolUse`.
4. **OpenIslandSetup** — Installer CLI for managing `~/.codex/config.toml` and `hooks.json`.

## Key data flow

### Codex path
Codex → hooks.json → OpenIslandHooks (stdin/stdout) → Unix socket → DemoBridgeServer → AppModel → UI

### Claude Code path
Claude Code → settings.json hooks → OpenIslandHooks (stdin/stdout) → Unix socket → DemoBridgeServer.handleClaudeHook → AppModel → UI

### Session discovery (on launch)
Restore cached sessions from registry → discover recent JSONL transcripts (`~/.claude/projects/`) → reconcile with active terminal processes → start live bridge.

## Supported scope (narrow by design)

- **Agents**: Codex (fully wired), Claude Code (hook-based integration)
- **Terminals**: Terminal.app, Ghostty
- Do NOT expand scope unless explicitly asked

## Build & test

```bash
swift build
swift test
swift run OpenIslandApp                            # run the app
swift build -c release --product OpenIslandHooks   # build hook binary
```

Open `Package.swift` in Xcode for the app target. Requires macOS 14+, Swift 6.2.

## Conventions

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`
- Each round of changes should be a single focused commit
- Prefer small end-to-end slices over speculative scaffolding
- Native macOS APIs over cross-platform abstractions
- Hooks fail open — if app/bridge unavailable, agents keep running unchanged
- The `SessionState.apply(_:)` reducer is the single source of truth for session mutations
- Bridge protocol uses newline-delimited JSON envelopes (`BridgeCodec`)
- All models are `Sendable` and `Codable`

## Important files

- `Sources/OpenIslandApp/AppModel.swift` — Central app state, session management, bridge lifecycle
- `Sources/OpenIslandApp/TerminalSessionAttachmentProbe.swift` — Ghostty/Terminal attachment matching
- `Sources/OpenIslandApp/ActiveAgentProcessDiscovery.swift` — Process discovery via ps/lsof
- `Sources/OpenIslandCore/SessionState.swift` — Pure state reducer for agent sessions
- `Sources/OpenIslandCore/AgentSession.swift` — Core session model and related types
- `Sources/OpenIslandCore/AgentEvent.swift` — Event enum driving all state transitions
- `Sources/OpenIslandCore/BridgeTransport.swift` — Unix socket protocol, codec, envelope types
- `Sources/OpenIslandCore/DemoBridgeServer.swift` — Bridge server handling hook payloads
- `Sources/OpenIslandCore/ClaudeHooks.swift` — Claude Code hook payload model and terminal detection
- `Sources/OpenIslandCore/ClaudeTranscriptDiscovery.swift` — Discovers sessions from `~/.claude/projects/` JSONL files
- `Sources/OpenIslandCore/ClaudeSessionRegistry.swift` — Persists/restores Claude sessions across app launches
- `Sources/OpenIslandCore/CodexHooks.swift` — Codex hook payload model
- `Sources/OpenIslandHooks/main.swift` — Hook CLI entry point
- `Sources/OpenIslandApp/OverlayPanelController.swift` — Notch/top-bar overlay window
- `docs/product.md` — Product scope and MVP boundary
- `docs/architecture.md` — System design and engineering decisions
- `AGENTS.md` — Working agreement for agent workflow
