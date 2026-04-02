# Vibe Island OSS

An open-source macOS notch and top-bar companion for AI coding agents.

The goal is to build a native Swift app that can monitor local agent sessions, surface permission requests and questions, and jump back into the right terminal or editor context without leaving flow.

## Status

Initial native scaffold is in place. The repository now contains a buildable macOS Swift package with:

- `VibeIslandCore` for shared event and session state logic
- `VibeIslandApp` for the SwiftUI and AppKit shell
- `VibeIslandHooks` for Codex hook ingestion over stdin/stdout
- a local Unix-socket bridge between the app and external hook processes
- core tests for session state transitions

## Product Direction

- Native macOS app built with SwiftUI and AppKit where needed.
- Local-first communication over Unix sockets or equivalent IPC.
- Support multiple coding agents over time, starting with one narrow integration.
- Focus on interaction, not just passive monitoring.

## Initial Milestones

1. `v0.1` Single-agent MVP with real Codex hook monitoring and overlay UI.
2. `v0.2` Approval flow hardening, terminal jump, and install automation.
3. `v0.3` Terminal jump, multi-session state, and external display behavior.
4. `v0.4` Multi-agent adapters and install/setup automation.

## Getting Started

```bash
swift test
swift build
open Package.swift
```

Open the package in Xcode to run the macOS app target. The app now starts an empty local bridge and waits for real Codex hook events. Use `Restart Demo` in the UI if you want the old mock timeline back.

## Codex Hook MVP

Enable the official Codex hook feature flag once:

```toml
[features]
codex_hooks = true
```

Build the helper once:

```bash
swift build -c release --product VibeIslandHooks
```

Then point Codex at a `hooks.json` file. A minimal `~/.codex/hooks.json` shape looks like:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ]
  }
}
```

The helper reads the Codex hook payload from `stdin`, forwards it to the app bridge over a Unix socket in `/tmp`, and only writes JSON to `stdout` when the island explicitly denies a `PreToolUse` Bash command. If the app or bridge is unavailable, the hook fails open and Codex keeps running unchanged.

## Repository Layout

- `Package.swift` Swift package entry point for the app and shared core module.
- `Sources/VibeIslandCore` Shared models, events, mock scenario, and session state reducer.
- `Sources/VibeIslandCore` also contains the wire protocol, local socket clients, Codex hook models, and bridge server.
- `Sources/VibeIslandHooks` Hook executable for Codex.
- `Sources/VibeIslandApp` SwiftUI app shell, menu bar entry, and overlay panel controller.
- `Tests/VibeIslandCoreTests` Core logic tests.
- `docs/product.md` Product scope, MVP boundary, and roadmap.
- `docs/architecture.md` System shape, event flow, and engineering decisions.

## Principles

- Keep the app local-first. No server dependency for core behavior.
- Build narrow slices end to end before adding more integrations.
- Prefer native platform APIs over cross-platform abstractions.
- Treat hooks, IPC, and focus-switching behavior as first-class engineering concerns.
- Keep the Terminal entrypoint unchanged for users. The app should attach to Codex, not replace it.

## Next Step

Polish the Codex hook adapter, add installation automation, and start wiring terminal jump behavior.
