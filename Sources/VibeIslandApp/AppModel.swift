import AppKit
import Foundation
import Observation
import VibeIslandCore

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason: Equatable {
    case click
    case hover
    case notification
    case boot
}

enum NotchContentType: Equatable {
    case sessions
    case menu
}

@MainActor
@Observable
final class AppModel {
    private static let overlayDisplayPreferenceDefaultsKey = "overlay.display.preference"
    private static let soundMutedDefaultsKey = "overlay.sound.muted"
    private static let liveSessionStalenessWindow: TimeInterval = 15 * 60
    static let hoverOpenDelay: TimeInterval = 1.0

    struct AcceptanceStep: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
    }

    var state = SessionState()
    var selectedSessionID: String?
    var notchStatus: NotchStatus = .closed
    var notchOpenReason: NotchOpenReason?
    var notchContentType: NotchContentType = .sessions
    var isOverlayVisible: Bool { notchStatus != .closed }
    var isCodexSetupBusy = false
    var isClaudeUsageSetupBusy = false
    var isBridgeReady = false
    var lastActionMessage = "Waiting for Codex hook events..."
    var codexHookStatus: CodexHookInstallationStatus?
    var claudeStatusLineStatus: ClaudeStatusLineInstallationStatus?
    var claudeUsageSnapshot: ClaudeUsageSnapshot?
    var codexUsageSnapshot: CodexUsageSnapshot?
    var hooksBinaryURL: URL?
    var overlayDisplayOptions: [OverlayDisplayOption] = []
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics?
    var isSoundMuted = false {
        didSet {
            guard isSoundMuted != oldValue else {
                return
            }

            UserDefaults.standard.set(isSoundMuted, forKey: Self.soundMutedDefaultsKey)
            lastActionMessage = isSoundMuted
                ? "Island sound notifications muted."
                : "Island sound notifications enabled."
        }
    }
    var overlayDisplaySelectionID = OverlayDisplayOption.automaticID {
        didSet {
            guard overlayDisplaySelectionID != oldValue else {
                return
            }

            persistOverlayDisplayPreference()
            refreshOverlayPlacement()
        }
    }

    @ObservationIgnored
    private var bridgeTask: Task<Void, Never>?

    @ObservationIgnored
    private let overlayPanelController = OverlayPanelController()

    @ObservationIgnored
    private let bridgeServer = DemoBridgeServer()

    @ObservationIgnored
    private let bridgeClient = LocalBridgeClient()

    @ObservationIgnored
    private let codexHookInstallationManager = CodexHookInstallationManager()

    @ObservationIgnored
    private let claudeStatusLineInstallationManager = ClaudeStatusLineInstallationManager()

    @ObservationIgnored
    private let terminalJumpService = TerminalJumpService()

    @ObservationIgnored
    private let codexSessionStore = CodexSessionStore()

    @ObservationIgnored
    private let codexRolloutWatcher = CodexRolloutWatcher()

    @ObservationIgnored
    private let codexRolloutDiscovery = CodexRolloutDiscovery()

    @ObservationIgnored
    private let terminalSessionAttachmentProbe = TerminalSessionAttachmentProbe()

    @ObservationIgnored
    private var codexSessionPersistenceTask: Task<Void, Never>?

    @ObservationIgnored
    private var sessionAttachmentMonitorTask: Task<Void, Never>?

    @ObservationIgnored
    private var claudeUsageMonitorTask: Task<Void, Never>?

    @ObservationIgnored
    private var codexUsageMonitorTask: Task<Void, Never>?

    init() {
        overlayDisplaySelectionID = UserDefaults.standard.string(
            forKey: Self.overlayDisplayPreferenceDefaultsKey
        ) ?? OverlayDisplayOption.automaticID
        isSoundMuted = UserDefaults.standard.bool(forKey: Self.soundMutedDefaultsKey)

        codexRolloutWatcher.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyTrackedEvent(event, updateLastActionMessage: false)
            }
        }

        refreshOverlayDisplayConfiguration()
    }

    var sessions: [AgentSession] {
        state.sessions
    }

    var surfacedSessions: [AgentSession] {
        sessionBuckets.primary
    }

    var recentSessions: [AgentSession] {
        sessionBuckets.overflow
    }

    var recentSessionCount: Int {
        recentSessions.count
    }

    var liveSessionCount: Int {
        state.liveSessionCount
    }

    var liveAttentionCount: Int {
        state.liveAttentionCount
    }

    var liveRunningCount: Int {
        state.liveRunningCount
    }

    var codexHooksInstalled: Bool {
        codexHookStatus?.managedHooksPresent == true
    }

    var claudeUsageInstalled: Bool {
        claudeStatusLineStatus?.managedStatusLineInstalled == true
    }

    var claudeUsageStatusTitle: String {
        guard let status = claudeStatusLineStatus else {
            return "Claude usage status unavailable"
        }

        if status.managedStatusLineInstalled {
            return "Claude usage bridge installed"
        }

        if status.hasConflictingStatusLine {
            return "Custom Claude status line detected"
        }

        return "Claude usage bridge not installed"
    }

    var claudeUsageStatusSummary: String {
        guard let status = claudeStatusLineStatus else {
            return "Reading ~/.claude/settings.json."
        }

        if status.managedStatusLineInstalled {
            if let summary = claudeUsageSummaryText {
                return "Caching rate limits from Claude Code · \(summary)"
            }
            return "Caching rate limits from Claude Code into \(status.cacheURL.path)."
        }

        if status.hasConflictingStatusLine {
            return "Vibe Island will not overwrite an existing Claude status line automatically."
        }

        return "Install a managed Claude status line to cache 5h and 7d usage locally."
    }

    var claudeUsageSummaryText: String? {
        guard let snapshot = claudeUsageSnapshot else {
            return nil
        }

        var components: [String] = []
        if let fiveHour = snapshot.fiveHour {
            components.append("5h \(fiveHour.roundedUsedPercentage)%")
        }
        if let sevenDay = snapshot.sevenDay {
            components.append("7d \(sevenDay.roundedUsedPercentage)%")
        }
        if let cachedAt = snapshot.cachedAt {
            components.append("updated \(relativeTimestampFormatter.localizedString(for: cachedAt, relativeTo: .now))")
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    var codexUsageStatusTitle: String {
        if codexUsageSnapshot?.isEmpty == false {
            return "Codex rate limits detected"
        }

        return "Waiting for Codex rate limits"
    }

    var codexUsageStatusSummary: String {
        if let summary = codexUsageSummaryText {
            return "Reading the latest local rollout token_count snapshots · \(summary)"
        }

        return "Passively reading ~/.codex/sessions/**/rollout-*.jsonl and extracting token_count.rate_limits."
    }

    var codexUsageSummaryText: String? {
        guard let snapshot = codexUsageSnapshot else {
            return nil
        }

        var components = snapshot.windows.map { window in
            "\(window.label) \(window.roundedUsedPercentage)%"
        }

        if let planType = snapshot.planType {
            components.append("plan \(planType)")
        }

        if let capturedAt = snapshot.capturedAt {
            components.append("updated \(relativeTimestampFormatter.localizedString(for: capturedAt, relativeTo: .now))")
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
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
        state.session(id: selectedSessionID) ?? surfacedSessions.first ?? state.activeActionableSession ?? state.sessions.first
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

        restorePersistedCodexSessions()
        discoverRecentCodexSessions()
        reconcileSessionAttachments()
        startSessionAttachmentMonitoringIfNeeded()
        hooksBinaryURL = HooksBinaryLocator.locate()
        refreshCodexHookStatus()
        refreshClaudeUsageState()
        startClaudeUsageMonitoringIfNeeded()
        refreshCodexUsageState()
        startCodexUsageMonitoringIfNeeded()
        refreshCodexRolloutTracking()
        refreshOverlayDisplayConfiguration()
        ensureOverlayPanel()
        performBootAnimation()

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
                        self.applyTrackedEvent(event)
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

    func select(sessionID: String) {
        selectedSessionID = sessionID
    }

    func toggleOverlay() {
        if notchStatus == .closed {
            notchOpen(reason: .click)
        } else {
            notchClose()
        }
    }

    func notchOpen(reason: NotchOpenReason) {
        notchOpenReason = reason
        notchStatus = .opened

        overlayPlacementDiagnostics = overlayPanelController.show(
            model: self,
            preferredScreenID: preferredOverlayScreenID
        )
        overlayPanelController.setInteractive(true)

        if let overlayPlacementDiagnostics {
            lastActionMessage = "Overlay showing on \(overlayPlacementDiagnostics.targetScreenName) as \(overlayPlacementDiagnostics.modeDescription.lowercased())."
        }
    }

    func notchClose() {
        notchStatus = .closed
        notchOpenReason = nil
        overlayPanelController.setInteractive(false)
        refreshOverlayPlacement()
    }

    func notchPop() {
        guard notchStatus == .closed else { return }
        notchStatus = .popping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.notchStatus == .popping else { return }
            self?.notchStatus = .closed
        }
    }

    func performBootAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.notchOpen(reason: .boot)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self?.notchOpenReason == .boot else { return }
                self?.notchClose()
            }
        }
    }

    func ensureOverlayPanel() {
        overlayPanelController.ensurePanel(model: self, preferredScreenID: preferredOverlayScreenID)
    }

    // Legacy compatibility
    func showOverlay() { notchOpen(reason: .click) }
    func hideOverlay() { notchClose() }

    func refreshOverlayDisplayConfiguration() {
        overlayDisplayOptions = overlayPanelController.availableDisplayOptions()

        let validSelectionIDs = Set(overlayDisplayOptions.map(\.id))
        if !validSelectionIDs.contains(overlayDisplaySelectionID) {
            overlayDisplaySelectionID = OverlayDisplayOption.automaticID
            return
        }

        refreshOverlayPlacement()
    }

    func refreshOverlayPlacement() {
        overlayPlacementDiagnostics = overlayPanelController.reposition(
            preferredScreenID: preferredOverlayScreenID
        )
    }

    private func refreshOverlayPlacementIfVisible() {
        guard notchStatus == .opened else {
            return
        }

        refreshOverlayPlacement()
    }

    func showControlCenter() {
        guard let window = NSApp.windows.first(where: { $0.title == "Vibe Island OSS" }) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleSoundMuted() {
        isSoundMuted.toggle()
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
            dismissOverlayForJump()
            let result = try terminalJumpService.jump(to: jumpTarget)
            lastActionMessage = result
        } catch {
            lastActionMessage = "Jump failed: \(error.localizedDescription)"
        }
    }

    func jumpToSession(_ session: AgentSession) {
        guard let jumpTarget = session.jumpTarget else {
            lastActionMessage = "No jump target is available yet."
            return
        }

        do {
            dismissOverlayForJump()
            let result = try terminalJumpService.jump(to: jumpTarget)
            lastActionMessage = result
        } catch {
            lastActionMessage = "Jump failed: \(error.localizedDescription)"
        }
    }

    func approvePermission(for sessionID: String, approved: Bool) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        send(
            .resolvePermission(sessionID: session.id, approved: approved),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func answerQuestion(for sessionID: String, answer: String) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        send(
            .answerQuestion(sessionID: session.id, answer: answer),
            userMessage: "Sending answer \"\(answer)\" for \(session.title)."
        )
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

    func refreshClaudeUsageState() {
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                self.claudeStatusLineStatus = try self.claudeStatusLineInstallationManager.status()
                self.claudeUsageSnapshot = try ClaudeUsageLoader.load()
            } catch {
                self.lastActionMessage = "Failed to read Claude usage state: \(error.localizedDescription)"
            }
        }
    }

    func refreshCodexUsageState() {
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try CodexUsageLoader.load()
                }.value
                self.codexUsageSnapshot = snapshot
            } catch {
                self.lastActionMessage = "Failed to read Codex usage state: \(error.localizedDescription)"
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

    func installClaudeUsageBridge() {
        updateClaudeUsageBridge(userMessage: "Installing Claude usage bridge.") { manager in
            try manager.install()
        }
    }

    func uninstallClaudeUsageBridge() {
        updateClaudeUsageBridge(userMessage: "Removing Claude usage bridge.") { manager in
            try manager.uninstall()
        }
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

    private func updateClaudeUsageBridge(
        userMessage: String,
        operation: @escaping (ClaudeStatusLineInstallationManager) throws -> ClaudeStatusLineInstallationStatus
    ) {
        isClaudeUsageSetupBusy = true
        lastActionMessage = userMessage

        Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.isClaudeUsageSetupBusy = false
            }

            do {
                let status = try operation(self.claudeStatusLineInstallationManager)
                self.claudeStatusLineStatus = status
                self.claudeUsageSnapshot = try ClaudeUsageLoader.load()
                if status.managedStatusLineInstalled {
                    self.lastActionMessage = "Claude usage bridge is installed. Start a Claude Code turn to refresh cached rate limits."
                } else {
                    self.lastActionMessage = "Claude usage bridge is not installed."
                }
            } catch {
                self.lastActionMessage = "Claude usage bridge update failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyTrackedEvent(
        _ event: AgentEvent,
        updateLastActionMessage: Bool = true
    ) {
        state.apply(event)
        markSessionAttached(for: event)
        synchronizeSelection()
        refreshCodexRolloutTracking()
        refreshOverlayPlacementIfVisible()
        scheduleCodexSessionPersistence()

        if updateLastActionMessage {
            lastActionMessage = describe(event)
        }

        if case .permissionRequested = event, notchStatus == .closed {
            notchPop()
        }
    }

    private func synchronizeSelection() {
        let surfacedIDs = Set(surfacedSessions.map(\.id))

        if let activeAction = state.activeActionableSession {
            selectedSessionID = activeAction.id
            return
        }

        guard let selectedSessionID,
              surfacedIDs.contains(selectedSessionID),
              state.session(id: selectedSessionID) != nil else {
            self.selectedSessionID = surfacedSessions.first?.id ?? state.sessions.first?.id
            return
        }
    }

    private func restorePersistedCodexSessions() {
        do {
            let loadedRecords = try codexSessionStore.load()
            let records = loadedRecords.filter {
                $0.updatedAt >= Date.now.addingTimeInterval(-86_400) && $0.shouldRestoreToLiveState
            }

            if records != loadedRecords {
                try? codexSessionStore.save(records)
            }

            guard !records.isEmpty else {
                return
            }

            state = SessionState(sessions: records.map(\.session))
            synchronizeSelection()
            refreshOverlayPlacementIfVisible()
            lastActionMessage = "Restored \(records.count) recent Codex session(s) from local cache."
        } catch {
            lastActionMessage = "Failed to restore Codex session cache: \(error.localizedDescription)"
        }
    }

    private func discoverRecentCodexSessions() {
        let records = codexRolloutDiscovery.discoverRecentSessions()
        guard !records.isEmpty else {
            return
        }

        let mergedSessions = mergeDiscoveredSessions(records.map(\.session))
        state = SessionState(sessions: mergedSessions)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()
        scheduleCodexSessionPersistence()
        lastActionMessage = "Discovered \(records.count) recent Codex session(s) from local rollouts."
    }

    private func refreshCodexRolloutTracking() {
        let targets = state.sessions.compactMap { session -> CodexRolloutWatchTarget? in
            guard session.tool == .codex,
                  let transcriptPath = session.codexMetadata?.transcriptPath,
                  !transcriptPath.isEmpty else {
                return nil
            }

            return CodexRolloutWatchTarget(
                sessionID: session.id,
                transcriptPath: transcriptPath
            )
        }

        codexRolloutWatcher.sync(targets: targets)
    }

    private func mergeDiscoveredSessions(_ discoveredSessions: [AgentSession]) -> [AgentSession] {
        var mergedByID = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.id, $0) })

        for discovered in discoveredSessions {
            if let existing = mergedByID[discovered.id] {
                mergedByID[discovered.id] = merge(discovered: discovered, into: existing)
            } else {
                mergedByID[discovered.id] = discovered
            }
        }

        return Array(mergedByID.values)
    }

    private func merge(discovered: AgentSession, into existing: AgentSession) -> AgentSession {
        var merged = existing
        let discoveredIsNewer = discovered.updatedAt >= existing.updatedAt

        if discoveredIsNewer {
            merged.title = discovered.title
            merged.phase = discovered.phase
            merged.summary = discovered.summary
            merged.updatedAt = discovered.updatedAt
            merged.permissionRequest = discovered.permissionRequest
            merged.questionPrompt = discovered.questionPrompt
        }

        merged.origin = existing.origin ?? discovered.origin
        merged.attachmentState = mergeAttachmentState(existing.attachmentState, discovered.attachmentState)
        merged.jumpTarget = existing.jumpTarget ?? discovered.jumpTarget
        merged.codexMetadata = mergeCodexMetadata(existing.codexMetadata, discovered.codexMetadata)

        return merged
    }

    private func mergeCodexMetadata(
        _ existing: CodexSessionMetadata?,
        _ discovered: CodexSessionMetadata?
    ) -> CodexSessionMetadata? {
        guard let existing else {
            return discovered?.isEmpty == true ? nil : discovered
        }

        guard let discovered else {
            return existing.isEmpty ? nil : existing
        }

        let merged = CodexSessionMetadata(
            transcriptPath: discovered.transcriptPath ?? existing.transcriptPath,
            initialUserPrompt: existing.initialUserPrompt ?? discovered.initialUserPrompt ?? discovered.lastUserPrompt,
            lastUserPrompt: discovered.lastUserPrompt ?? existing.lastUserPrompt,
            lastAssistantMessage: discovered.lastAssistantMessage ?? existing.lastAssistantMessage,
            currentTool: discovered.currentTool ?? existing.currentTool,
            currentCommandPreview: discovered.currentCommandPreview ?? existing.currentCommandPreview
        )
        return merged.isEmpty ? nil : merged
    }

    private func dismissOverlayForJump() {
        guard isOverlayVisible else {
            return
        }

        notchClose()
    }

    private var preferredOverlayScreenID: String? {
        overlayDisplaySelectionID == OverlayDisplayOption.automaticID
            ? nil
            : overlayDisplaySelectionID
    }

    private var sessionBuckets: (primary: [AgentSession], overflow: [AgentSession]) {
        let now = Date.now
        let rankedSessions = state.sessions.sorted { lhs, rhs in
            let lhsScore = displayPriority(for: lhs, now: now)
            let rhsScore = displayPriority(for: rhs, now: now)

            if lhsScore == rhsScore {
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }

                return lhs.islandActivityDate > rhs.islandActivityDate
            }

            return lhsScore > rhsScore
        }

        let primary = rankedSessions.filter(\.isAttachedToTerminal)
        let primaryIDs = Set(primary.map(\.id))
        let overflow = rankedSessions.filter { !primaryIDs.contains($0.id) }
        return (primary, overflow)
    }

    private func displayPriority(for session: AgentSession, now: Date) -> Int {
        var score = 0

        switch session.attachmentState {
        case .attached:
            score += 12_000
        case .stale:
            score += 1_000
        case .detached:
            break
        }

        if session.phase.requiresAttention {
            score += 10_000
        }

        if session.codexMetadata?.currentTool?.isEmpty == false {
            score += 6_000
        }

        if session.jumpTarget != nil {
            score += 4_000
        }

        switch session.phase {
        case .running:
            score += 2_000
        case .waitingForApproval:
            score += 1_500
        case .waitingForAnswer:
            score += 1_200
        case .completed:
            score += 600
        }

        let age = now.timeIntervalSince(session.islandActivityDate)
        switch age {
        case ..<120:
            score += 500
        case ..<900:
            score += 250
        case ..<3_600:
            score += 120
        case ..<21_600:
            score += 40
        default:
            break
        }

        return score
    }

    private func persistOverlayDisplayPreference() {
        let defaults = UserDefaults.standard

        if overlayDisplaySelectionID == OverlayDisplayOption.automaticID {
            defaults.removeObject(forKey: Self.overlayDisplayPreferenceDefaultsKey)
        } else {
            defaults.set(overlayDisplaySelectionID, forKey: Self.overlayDisplayPreferenceDefaultsKey)
        }
    }

    private func startSessionAttachmentMonitoringIfNeeded() {
        guard sessionAttachmentMonitorTask == nil else {
            return
        }

        sessionAttachmentMonitorTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                self.reconcileSessionAttachments()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func startClaudeUsageMonitoringIfNeeded() {
        guard claudeUsageMonitorTask == nil else {
            return
        }

        claudeUsageMonitorTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                self.refreshClaudeUsageState()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func startCodexUsageMonitoringIfNeeded() {
        guard codexUsageMonitorTask == nil else {
            return
        }

        codexUsageMonitorTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                self.refreshCodexUsageState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func reconcileSessionAttachments() {
        let sessions = state.sessions.filter(\.isTrackedLiveCodexSession)
        guard !sessions.isEmpty else {
            return
        }

        let resolutions = terminalSessionAttachmentProbe.sessionResolutions(for: sessions)
        let attachmentUpdates = resolutions.mapValues(\.attachmentState)
        let jumpTargetUpdates = resolutions.reduce(into: [String: JumpTarget]()) { partialResult, entry in
            if let correctedJumpTarget = entry.value.correctedJumpTarget {
                partialResult[entry.key] = correctedJumpTarget
            }
        }

        let attachmentsChanged = state.reconcileAttachmentStates(attachmentUpdates)
        let jumpTargetsChanged = state.reconcileJumpTargets(jumpTargetUpdates)
        guard attachmentsChanged || jumpTargetsChanged else {
            return
        }

        synchronizeSelection()
        refreshOverlayPlacementIfVisible()
        scheduleCodexSessionPersistence()
    }

    private func markSessionAttached(for event: AgentEvent) {
        guard let sessionID = sessionID(for: event) else {
            return
        }

        _ = state.reconcileAttachmentStates([sessionID: .attached])
    }

    private func sessionID(for event: AgentEvent) -> String? {
        switch event {
        case let .sessionStarted(payload):
            payload.sessionID
        case let .activityUpdated(payload):
            payload.sessionID
        case let .permissionRequested(payload):
            payload.sessionID
        case let .questionAsked(payload):
            payload.sessionID
        case let .sessionCompleted(payload):
            payload.sessionID
        case let .jumpTargetUpdated(payload):
            payload.sessionID
        case let .sessionMetadataUpdated(payload):
            payload.sessionID
        }
    }

    private func mergeAttachmentState(
        _ existing: SessionAttachmentState,
        _ discovered: SessionAttachmentState
    ) -> SessionAttachmentState {
        switch (existing, discovered) {
        case (.attached, _), (_, .attached):
            .attached
        case (.stale, _), (_, .stale):
            .stale
        case (.detached, .detached):
            .detached
        }
    }

    private func scheduleCodexSessionPersistence() {
        codexSessionPersistenceTask?.cancel()

        let records = state.sessions
            .filter { $0.isTrackedLiveCodexSession && $0.updatedAt >= Date.now.addingTimeInterval(-86_400) }
            .map(CodexTrackedSessionRecord.init(session:))
        let store = codexSessionStore

        codexSessionPersistenceTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            try? store.save(records)
        }
    }

    private func describe(_ event: AgentEvent) -> String {
        switch event {
        case let .sessionStarted(payload):
            return "Session started: \(payload.title)"
        case let .activityUpdated(payload):
            return payload.summary
        case let .permissionRequested(payload):
            return payload.request.summary
        case let .questionAsked(payload):
            return payload.prompt.title
        case let .sessionCompleted(payload):
            return payload.summary
        case let .jumpTargetUpdated(payload):
            return "Jump target updated to \(payload.jumpTarget.terminalApp)."
        case let .sessionMetadataUpdated(payload):
            if let currentTool = payload.codexMetadata.currentTool {
                return "Codex is running \(currentTool)."
            }

            return payload.codexMetadata.lastAssistantMessage ?? "Codex session metadata updated."
        }
    }

    private var relativeTimestampFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }
}
