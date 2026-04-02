import AppKit
import Foundation
import Observation
import VibeIslandCore

@MainActor
@Observable
final class AppModel {
    var state = SessionState()
    var selectedSessionID: String?
    var isOverlayVisible = false
    var lastActionMessage = "Waiting for Codex hook events..."

    @ObservationIgnored
    private var bridgeTask: Task<Void, Never>?

    @ObservationIgnored
    private let overlayPanelController = OverlayPanelController()

    @ObservationIgnored
    private let bridgeServer = DemoBridgeServer()

    @ObservationIgnored
    private let bridgeClient = LocalBridgeClient()

    var sessions: [AgentSession] {
        state.sessions
    }

    var focusedSession: AgentSession? {
        state.session(id: selectedSessionID) ?? state.activeActionableSession ?? state.sessions.first
    }

    func startIfNeeded() {
        guard bridgeTask == nil else {
            return
        }

        do {
            try bridgeServer.start()
            let stream = try bridgeClient.connect()

            Task { [weak self] in
                guard let self else {
                    return
                }

                do {
                    try await self.bridgeClient.send(.registerClient(role: .observer))
                    self.lastActionMessage = "Bridge ready. Waiting for Codex hook events."
                } catch {
                    self.lastActionMessage = "Failed to register bridge observer: \(error.localizedDescription)"
                }
            }

            bridgeTask = Task { [weak self] in
                guard let self else {
                    return
                }

                do {
                    for try await event in stream {
                        self.state.apply(event)

                        if self.selectedSessionID == nil || self.state.session(id: self.selectedSessionID) == nil {
                            self.selectedSessionID = self.state.activeActionableSession?.id ?? self.state.sessions.first?.id
                        } else if let activeAction = self.state.activeActionableSession {
                            self.selectedSessionID = activeAction.id
                        }

                        self.lastActionMessage = self.describe(event)
                    }
                } catch {
                    self.lastActionMessage = "Bridge disconnected: \(error.localizedDescription)"
                }
            }
        } catch {
            lastActionMessage = "Failed to start local bridge: \(error.localizedDescription)"
        }
    }

    func resetDemo() {
        send(.resetDemo, userMessage: "Resetting bridge demo state.")
    }

    func select(sessionID: String) {
        selectedSessionID = sessionID
    }

    func toggleOverlay() {
        if isOverlayVisible {
            overlayPanelController.hide()
            isOverlayVisible = false
        } else {
            overlayPanelController.show(model: self)
            isOverlayVisible = true
        }
    }

    func approveFocusedPermission(_ approved: Bool) {
        guard let session = focusedSession else {
            return
        }

        send(
            .resolvePermission(sessionID: session.id, approved: approved),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func answerFocusedQuestion(_ answer: String) {
        guard let session = focusedSession else {
            return
        }

        send(
            .answerQuestion(sessionID: session.id, answer: answer),
            userMessage: "Sending answer \"\(answer)\" for \(session.title)."
        )
    }

    func jumpToFocusedSession() {
        guard let session = focusedSession, let jumpTarget = session.jumpTarget else {
            lastActionMessage = "No jump target is available yet."
            return
        }

        lastActionMessage = "Jump target: \(jumpTarget.terminalApp) · \(jumpTarget.workspaceName) · \(jumpTarget.paneTitle)"
        NSApp.activate(ignoringOtherApps: true)
    }

    private func send(_ command: BridgeCommand, userMessage: String) {
        lastActionMessage = userMessage

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.bridgeClient.send(command)
            } catch {
                self.lastActionMessage = "Failed to send bridge command: \(error.localizedDescription)"
            }
        }
    }

    private func describe(_ event: AgentEvent) -> String {
        switch event {
        case let .sessionStarted(payload):
            "Session started: \(payload.title)"
        case let .activityUpdated(payload):
            payload.summary
        case let .permissionRequested(payload):
            payload.request.summary
        case let .questionAsked(payload):
            payload.prompt.title
        case let .sessionCompleted(payload):
            payload.summary
        case let .jumpTargetUpdated(payload):
            "Jump target updated to \(payload.jumpTarget.terminalApp)."
        }
    }
}
