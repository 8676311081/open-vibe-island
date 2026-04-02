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
        let server = DemoBridgeServer(socketURL: socketURL)
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
        let server = DemoBridgeServer(socketURL: socketURL, approvalTimeout: 5)
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
