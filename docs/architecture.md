# Architecture Notes

## System Shape

The project will likely split into three layers:

1. `macOS app`
   Renders the notch or top-bar UI, owns state presentation, and handles user interaction.
2. `bridge`
   Receives agent events locally and exposes a stable event stream to the app.
3. `agent adapters`
   Translate tool-specific hooks or config into a shared event model.

## Initial Event Model

The shared model should support:

- session started
- session updated
- permission requested
- question asked
- session completed
- jump target updated

Each event should carry a stable session identifier, tool name, timestamps, and enough metadata to route approvals or focus changes.

## Likely Technologies

- SwiftUI for most UI composition
- AppKit for panel behavior, status item control, and activation policy edge cases
- Unix domain sockets or local stream IPC for app and bridge communication
- JSON event envelopes for debugging and adapter simplicity

## Current Slice

The current bridge server still lives inside the app process for convenience, but the transport boundary is now real:

1. Codex runs in the user’s existing terminal session.
2. Codex invokes a repo-built `VibeIslandHooks` helper from `hooks.json`.
3. The helper forwards hook payloads to the app bridge over a Unix socket.
4. The app consumes normalized `AgentEvent` values from that socket and sends approval commands back over the same bridge.

For `PreToolUse`, the hook helper waits for the bridge response. If the island denies the request, the helper writes the blocking JSON shape that Codex already understands. If the app is unavailable, the helper fails open so the terminal flow remains unchanged.

## Suggested Build Order

1. Define the shared event schema
2. Keep Codex terminal entry unchanged and attach through hooks
3. Use the mock publisher only as a fallback/demo mode
4. Harden the approval loop for `PreToolUse`
5. Add install automation and terminal focus restoration

## Open Questions

- When should the bridge become a standalone launch agent or helper process?
- How should we install and rollback `hooks.json` safely for users?
- How much terminal-jump accuracy is possible without private APIs?
- Which permissions are required for reliable focus restoration across terminals and IDEs?

## Engineering Rules

- Preserve a clean separation between UI state and transport concerns.
- Version the event schema early so adapters can evolve safely.
- Keep setup reversible when editing third-party tool config files.
- Add mock fixtures for every event type before wiring real integrations.
