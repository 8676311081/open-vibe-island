import AppKit
import Foundation
import Observation
import VibeIslandCore

@MainActor
@Observable
final class AppModel {
    struct AcceptanceStep: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
    }

    var state = SessionState()
    var selectedSessionID: String?
    var isOverlayVisible = false
    var isCodexSetupBusy = false
    var isBridgeReady = false
    var lastActionMessage = "Waiting for Codex hook events..."
    var codexHookStatus: CodexHookInstallationStatus?
    var hooksBinaryURL: URL?

    @ObservationIgnored
    private var bridgeTask: Task<Void, Never>?

    @ObservationIgnored
    private let overlayPanelController = OverlayPanelController()

    @ObservationIgnored
    private weak var controlCenterWindowController: ControlCenterWindowController?

    @ObservationIgnored
    private let bridgeServer = BridgeServer()

    @ObservationIgnored
    private let bridgeClient = LocalBridgeClient()

    @ObservationIgnored
    private let codexHookInstallationManager = CodexHookInstallationManager()

    @ObservationIgnored
    private let terminalJumpService = TerminalJumpService()

    var sessions: [AgentSession] {
        state.sessions
    }

    var codexHooksInstalled: Bool {
        codexHookStatus?.managedHooksPresent == true
    }

    var codexHookStatusTitle: String {
        if codexHooksInstalled {
            return "Codex hooks installed"
        }

        if hooksBinaryURL == nil {
            return "Hook binary not found"
        }

        return "Codex hooks not installed"
    }

    var codexHookStatusSummary: String {
        guard let status = codexHookStatus else {
            return "Reading ~/.codex state."
        }

        if codexHooksInstalled {
            let featureText = status.featureFlagEnabled ? "feature on" : "feature off"
            return "\(featureText) · managed hooks present"
        }

        if hooksBinaryURL == nil {
            return "Build VibeIslandHooks before installing."
        }

        return status.featureFlagEnabled ? "feature on · no managed hooks" : "feature off · no managed hooks"
    }

    var focusedSession: AgentSession? {
        state.session(id: selectedSessionID) ?? state.activeActionableSession ?? state.sessions.first
    }

    var hasAnySession: Bool {
        !sessions.isEmpty
    }

    var hasCodexSession: Bool {
        sessions.contains(where: { $0.tool == .codex })
    }

    var hasJumpableSession: Bool {
        sessions.contains(where: { $0.jumpTarget != nil })
    }

    var acceptanceSteps: [AcceptanceStep] {
        [
            AcceptanceStep(
                id: "bridge",
                title: "Bridge ready",
                detail: "The app must own the local socket and register as a bridge observer.",
                isComplete: isBridgeReady
            ),
            AcceptanceStep(
                id: "hooks",
                title: "Codex hooks installed",
                detail: "Managed `hooks.json` entries should be present in `~/.codex`.",
                isComplete: codexHooksInstalled
            ),
            AcceptanceStep(
                id: "overlay",
                title: "Island visible",
                detail: "Show the overlay at least once so the notch/top-bar surface is visible.",
                isComplete: isOverlayVisible
            ),
            AcceptanceStep(
                id: "session",
                title: "A Codex session is observed",
                detail: "Start Codex in Terminal and wait for the first session row to appear.",
                isComplete: hasCodexSession
            ),
            AcceptanceStep(
                id: "jump",
                title: "Jump target captured",
                detail: "At least one session should include terminal jump metadata.",
                isComplete: hasJumpableSession
            ),
        ]
    }

    var acceptanceCompletedCount: Int {
        acceptanceSteps.filter(\.isComplete).count
    }

    var isReadyForFirstAcceptance: Bool {
        acceptanceSteps.prefix(3).allSatisfy(\.isComplete)
    }

    var hasPassedAcceptanceFlow: Bool {
        acceptanceSteps.allSatisfy(\.isComplete)
    }

    var acceptanceStatusTitle: String {
        if hasPassedAcceptanceFlow {
            return "v0.1 acceptance passed"
        }

        if isReadyForFirstAcceptance {
            return "Ready for v0.1 acceptance"
        }

        return "v0.1 acceptance not ready"
    }

    var acceptanceStatusSummary: String {
        if hasPassedAcceptanceFlow {
            return "The current build has completed the first-run checklist end to end."
        }

        if isReadyForFirstAcceptance {
            return "You can start your first acceptance run now. Launch Codex in Terminal and walk the last two steps."
        }

        return "Finish the setup steps in the left column, then start Codex from Terminal."
    }

    func startIfNeeded() {
        guard bridgeTask == nil else {
            return
        }

        hooksBinaryURL = HooksBinaryLocator.locate()
        refreshCodexHookStatus()

        do {
            try bridgeServer.start()
            let stream = try bridgeClient.connect()

            Task { [weak self] in
                guard let self else {
                    return
                }

                do {
                    try await self.bridgeClient.send(.registerClient(role: .observer))
                    self.isBridgeReady = true
                    self.lastActionMessage = "Bridge ready. Waiting for Codex hook events."
                } catch {
                    self.isBridgeReady = false
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
                    self.isBridgeReady = false
                    self.lastActionMessage = "Bridge disconnected: \(error.localizedDescription)"
                }
            }
        } catch {
            isBridgeReady = false
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

    func attach(controlCenterWindowController: ControlCenterWindowController) {
        self.controlCenterWindowController = controlCenterWindowController
    }

    func showControlCenter() {
        controlCenterWindowController?.show()
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

        do {
            let result = try terminalJumpService.jump(to: jumpTarget)
            lastActionMessage = result
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            lastActionMessage = "Jump failed: \(error.localizedDescription)"
        }
    }

    func refreshCodexHookStatus() {
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let status = try self.codexHookInstallationManager.status(hooksBinaryURL: self.hooksBinaryURL)
                self.codexHookStatus = status
            } catch {
                self.lastActionMessage = "Failed to read Codex hook status: \(error.localizedDescription)"
            }
        }
    }

    func installCodexHooks() {
        guard let hooksBinaryURL else {
            lastActionMessage = "Could not find a local VibeIslandHooks binary. Build the package first."
            return
        }

        updateCodexHooks(userMessage: "Installing Codex hooks.") { manager in
            try manager.install(hooksBinaryURL: hooksBinaryURL)
        }
    }

    func uninstallCodexHooks() {
        updateCodexHooks(userMessage: "Removing Codex hooks.") { manager in
            try manager.uninstall()
        }
    }

    func startAcceptanceDemo() {
        if !isOverlayVisible {
            toggleOverlay()
        }
        resetDemo()
        lastActionMessage = "Acceptance demo started. The overlay is visible and the demo timeline has been reset."
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

    private func updateCodexHooks(
        userMessage: String,
        operation: @escaping (CodexHookInstallationManager) throws -> CodexHookInstallationStatus
    ) {
        isCodexSetupBusy = true
        lastActionMessage = userMessage

        Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.isCodexSetupBusy = false
            }

            do {
                let status = try operation(self.codexHookInstallationManager)
                self.codexHookStatus = status
                if status.managedHooksPresent {
                    self.lastActionMessage = "Codex hooks are installed and ready."
                } else {
                    self.lastActionMessage = "Codex hooks are not installed."
                }
            } catch {
                self.lastActionMessage = "Codex hook update failed: \(error.localizedDescription)"
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
