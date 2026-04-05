import Foundation
import Testing
@testable import VibeIslandCore

struct SessionStateTests {
    @Test
    func appliesPermissionAndQuestionEventsToExistingSessions() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var state = SessionState()

        state.apply(
            .sessionStarted(
                SessionStarted(
                    sessionID: "session-1",
                    title: "Fix auth bug",
                    tool: .codex,
                    summary: "Booting up",
                    timestamp: startedAt
                )
            )
        )

        state.apply(
            .permissionRequested(
                PermissionRequested(
                    sessionID: "session-1",
                    request: PermissionRequest(
                        title: "Edit file",
                        summary: "Wants to edit middleware",
                        affectedPath: "src/auth/middleware.ts"
                    ),
                    timestamp: startedAt.addingTimeInterval(5)
                )
            )
        )

        #expect(state.attentionCount == 1)
        #expect(state.activeActionableSession?.phase == .waitingForApproval)
        #expect(state.activeActionableSession?.permissionRequest?.affectedPath == "src/auth/middleware.ts")

        state.apply(
            .questionAsked(
                QuestionAsked(
                    sessionID: "session-1",
                    prompt: QuestionPrompt(
                        title: "Which environment?",
                        options: ["Production", "Staging"]
                    ),
                    timestamp: startedAt.addingTimeInterval(10)
                )
            )
        )

        #expect(state.activeActionableSession?.phase == .waitingForAnswer)
        #expect(state.activeActionableSession?.questionPrompt?.options == ["Production", "Staging"])
        #expect(state.activeActionableSession?.permissionRequest == nil)
    }

    @Test
    func resolvesUserActionsAndKeepsSessionsSortedByRecency() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "older",
                    title: "Older session",
                    tool: .claudeCode,
                    phase: .running,
                    summary: "Working",
                    updatedAt: startedAt
                ),
                AgentSession(
                    id: "newer",
                    title: "Newer session",
                    tool: .codex,
                    phase: .waitingForApproval,
                    summary: "Needs approval",
                    updatedAt: startedAt.addingTimeInterval(5),
                    permissionRequest: PermissionRequest(
                        title: "Edit users.ts",
                        summary: "Needs access",
                        affectedPath: "src/routes/users.ts"
                    )
                ),
            ]
        )

        state.resolvePermission(
            sessionID: "newer",
            approved: true,
            at: startedAt.addingTimeInterval(20)
        )

        #expect(state.sessions.first?.id == "newer")
        #expect(state.sessions.first?.phase == .running)
        #expect(state.sessions.first?.permissionRequest == nil)

        state.answerQuestion(
            sessionID: "older",
            answer: "Production",
            at: startedAt.addingTimeInterval(25)
        )

        #expect(state.sessions.first?.id == "older")
        #expect(state.sessions.first?.summary == "Answered: Production")
    }

    @Test
    func bridgeEnvelopeRoundTripsThroughLineCodec() throws {
        let envelope = BridgeEnvelope.event(
            .permissionRequested(
                PermissionRequested(
                    sessionID: "session-42",
                    request: PermissionRequest(
                        title: "Edit middleware",
                        summary: "Needs to edit auth middleware.",
                        affectedPath: "src/auth/middleware.ts"
                    ),
                    timestamp: Date(timeIntervalSince1970: 3_000)
                )
            )
        )

        var buffer = try BridgeCodec.encodeLine(envelope)
        let decoded = try BridgeCodec.decodeLines(from: &buffer)

        #expect(decoded == [envelope])
        #expect(buffer.isEmpty)
    }

    @Test
    func localBridgeAcceptsResetDemoCommand() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let client = LocalBridgeClient(socketURL: socketURL)
        let stream = try client.connect()
        defer { client.disconnect() }
        try await client.send(.registerClient(role: .observer))

        var iterator = stream.makeAsyncIterator()

        try await client.send(.resetDemo)

        let resetFirstEvent = try await nextEvent(from: &iterator)
        let resetSecondEvent = try await nextEvent(from: &iterator)
        let resetThirdEvent = try await nextEvent(from: &iterator)
        let resetBatch = [resetFirstEvent, resetSecondEvent, resetThirdEvent]

        #expect(resetBatch.count == 3)
        #expect(resetBatch[0].isSessionStarted)
        #expect(resetBatch[1].isSessionStarted)
        #expect(resetBatch[2].isSessionStarted)
    }

    @Test
    func codexPreToolUseWaitsForApprovalAndReturnsDenyDirective() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL, approvalTimeout: 5)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let payload = CodexHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .preToolUse,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: "codex-session-1",
            transcriptPath: nil,
            turnID: "turn-1",
            toolName: "Bash",
            toolUseID: "tool-use-1",
            toolInput: CodexHookToolInput(command: "rm -rf build")
        )

        let requestTask = Task {
            try BridgeCommandClient(socketURL: socketURL).send(.processCodexHook(payload))
        }

        var iterator = stream.makeAsyncIterator()
        let startedEvent = try await nextEvent(from: &iterator)
        let permissionEvent = try await nextEvent(from: &iterator)

        #expect(startedEvent.isSessionStarted)
        #expect(permissionEvent.isPermissionRequested)

        try await observer.send(.resolvePermission(sessionID: "codex-session-1", approved: false))

        let response = try await requestTask.value
        #expect(response == .codexHookDirective(.deny(reason: "Permission denied in Vibe Island.")))
    }

    @Test
    func codexHookInstallerMergesManagedGroupsWithoutDroppingUnrelatedHooks() throws {
        let existing = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/bin/true",
                    "statusMessage": "Other hook"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let mutation = try CodexHookInstaller.installHooksJSON(
            existingData: existing,
            hookCommand: "'/tmp/VibeIslandHooks'"
        )

        #expect(mutation.changed)
        let root = try jsonObject(from: mutation.contents)
        let hooks = root["hooks"] as? [String: Any]
        let stopGroups = hooks?["Stop"] as? [[String: Any]]
        let stopCommands = stopGroups?
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String } ?? []
        let managedStopHook = stopGroups?
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .first(where: { $0["command"] as? String == "'/tmp/VibeIslandHooks'" })

        #expect(stopCommands.contains("/usr/bin/true"))
        #expect(stopCommands.contains("'/tmp/VibeIslandHooks'"))
        #expect(managedStopHook?["statusMessage"] == nil)

        let preToolGroups = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(preToolGroups?.contains(where: { $0["matcher"] as? String == "Bash" }) == true)
    }

    @Test
    func codexHookInstallerUninstallRemovesOnlyManagedHooks() throws {
        let existing = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/tmp/VibeIslandHooks'",
                    "statusMessage": "Managed by Vibe Island"
                  },
                  {
                    "type": "command",
                    "command": "/usr/bin/true",
                    "statusMessage": "Other hook"
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)

        let mutation = try CodexHookInstaller.uninstallHooksJSON(
            existingData: existing,
            managedCommand: "'/tmp/VibeIslandHooks'"
        )

        #expect(mutation.changed)
        #expect(mutation.hasRemainingHooks)

        let root = try jsonObject(from: mutation.contents)
        let hooks = root["hooks"] as? [String: Any]
        let stopGroups = hooks?["Stop"] as? [[String: Any]]
        let stopCommands = stopGroups?
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String } ?? []

        #expect(stopCommands == ["/usr/bin/true"])
    }

    @Test
    func codexHookInstallerEnablesAndRemovesFeatureFlag() {
        let initialConfig = """
        personality = "pragmatic"

        [projects."/tmp"]
        trust_level = "trusted"
        """

        let enabled = CodexHookInstaller.enableCodexHooksFeature(in: initialConfig)
        #expect(enabled.changed)
        #expect(enabled.featureEnabledByInstaller)
        #expect(enabled.contents.contains("[features]"))
        #expect(enabled.contents.contains("codex_hooks = true"))

        let removed = CodexHookInstaller.disableCodexHooksFeatureIfManaged(in: enabled.contents)
        #expect(removed.changed)
        #expect(!removed.contents.contains("codex_hooks = true"))
    }

    @Test
    func codexHookPayloadInfersTerminalAppFromRuntimeEnvironment() throws {
        let payload = CodexHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .sessionStart,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: "session-1",
            transcriptPath: nil
        )

        let inferredITerm = payload.withRuntimeContext(environment: [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t0p0",
        ])
        #expect(inferredITerm.terminalApp == "iTerm")

        let inferredGhostty = payload.withRuntimeContext(environment: [
            "TERM_PROGRAM": "ghostty",
        ])
        #expect(inferredGhostty.terminalApp == "Ghostty")
        #expect(inferredGhostty.defaultJumpTarget.workingDirectory == "/tmp/worktree")
    }

    @Test
    func codexHookPayloadCarriesSessionLocatorIntoJumpTarget() {
        let payload = CodexHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .sessionStart,
            model: "gpt-5-codex",
            permissionMode: .default,
            sessionID: "session-1",
            terminalApp: "iTerm",
            terminalSessionID: "A6C5F356-DEED-40F7-A787-AB9DADF27AD6",
            terminalTTY: "/dev/ttys022",
            terminalTitle: "codex ~/P/vibe-island",
            transcriptPath: nil
        )

        let jumpTarget = payload.defaultJumpTarget
        #expect(jumpTarget.terminalApp == "iTerm")
        #expect(jumpTarget.terminalSessionID == "A6C5F356-DEED-40F7-A787-AB9DADF27AD6")
        #expect(jumpTarget.terminalTTY == "/dev/ttys022")
        #expect(jumpTarget.paneTitle == "codex ~/P/vibe-island")
    }

    @Test
    func codexHookInstallationManagerRoundTripsInstallAndUninstall() throws {
        let codexDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-island-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = CodexHookInstallationManager(codexDirectory: codexDirectory)
        let hooksBinaryURL = codexDirectory.appendingPathComponent("VibeIslandHooks")

        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try Data().write(to: hooksBinaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooksBinaryURL.path)

        defer {
            try? FileManager.default.removeItem(at: codexDirectory)
        }

        let installed = try manager.install(hooksBinaryURL: hooksBinaryURL)
        #expect(installed.featureFlagEnabled)
        #expect(installed.managedHooksPresent)
        #expect(installed.manifest?.hookCommand == CodexHookInstaller.hookCommand(for: hooksBinaryURL.path))
        let hooksData = try Data(contentsOf: installed.hooksURL)
        let installedHooks = try jsonObject(from: hooksData)
        let installedStopGroups = (installedHooks["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        let installedManagedHook = installedStopGroups?
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .first(where: { $0["command"] as? String == CodexHookInstaller.hookCommand(for: hooksBinaryURL.path) })
        #expect(installedManagedHook?["statusMessage"] == nil)

        let reloaded = try manager.status(hooksBinaryURL: hooksBinaryURL)
        #expect(reloaded.managedHooksPresent)
        #expect(reloaded.featureFlagEnabled)

        let uninstalled = try manager.uninstall()
        #expect(!uninstalled.managedHooksPresent)
        #expect(!FileManager.default.fileExists(atPath: uninstalled.manifestURL.path))
    }
}

private enum SessionStateTestError: Error {
    case streamEnded
}

private func nextEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator
) async throws -> AgentEvent {
    guard let event = try await iterator.next() else {
        throw SessionStateTestError.streamEnded
    }

    return event
}

private extension AgentEvent {
    var isSessionStarted: Bool {
        if case .sessionStarted = self {
            true
        } else {
            false
        }
    }

    var isPermissionRequested: Bool {
        if case .permissionRequested = self {
            true
        } else {
            false
        }
    }
}

private func jsonObject(from data: Data?) throws -> [String: Any] {
    guard let data else {
        return [:]
    }

    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}
