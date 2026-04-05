import Dispatch
import Darwin
import Foundation

public final class BridgeServer: @unchecked Sendable {
    private struct ClientConnection {
        let id: UUID
        let fileDescriptor: Int32
        let readSource: DispatchSourceRead
        var role: BridgeClientRole?
        var buffer = Data()
    }

    private struct PendingApproval {
        let clientID: UUID
        let timeoutItem: DispatchWorkItem
    }

    private let socketURL: URL
    private let approvalTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.vibeisland.bridge.server")
    private let queueKey = DispatchSpecificKey<Void>()

    private var listeningFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [UUID: ClientConnection] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    private var scheduledItems: [DispatchWorkItem] = []
    private var state = SessionState()

    public init(
        socketURL: URL = BridgeSocketLocation.defaultURL,
        approvalTimeout: TimeInterval = 45
    ) {
        self.socketURL = socketURL
        self.approvalTimeout = approvalTimeout
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard listeningFileDescriptor == -1 else {
            return
        }

        let parentURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: socketURL)

        let listeningFileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningFileDescriptor != -1 else {
            throw BridgeTransportError.systemCallFailed("socket", errno)
        }

        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                listeningFileDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) != -1 else {
                throw BridgeTransportError.systemCallFailed("setsockopt", errno)
            }

            try withUnixSocketAddress(path: socketURL.path) { address, length in
                guard bind(listeningFileDescriptor, address, length) != -1 else {
                    throw BridgeTransportError.systemCallFailed("bind", errno)
                }
            }

            guard listen(listeningFileDescriptor, 16) != -1 else {
                throw BridgeTransportError.systemCallFailed("listen", errno)
            }

            try makeSocketNonBlocking(listeningFileDescriptor)
        } catch {
            close(listeningFileDescriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }

        self.listeningFileDescriptor = listeningFileDescriptor

        let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listeningFileDescriptor, queue: queue)
        acceptSource.setEventHandler { [weak self] in
            self?.acceptPendingClients()
        }
        acceptSource.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if self.listeningFileDescriptor != -1 {
                close(self.listeningFileDescriptor)
                self.listeningFileDescriptor = -1
            }
        }
        self.acceptSource = acceptSource
        acceptSource.resume()
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync {
                stopLocked()
            }
        }
    }

    private func stopLocked() {
        scheduledItems.forEach { $0.cancel() }
        scheduledItems.removeAll()

        pendingApprovals.values.forEach { $0.timeoutItem.cancel() }
        pendingApprovals.removeAll()

        let activeConnections = Array(clients.values)
        activeConnections.forEach { $0.readSource.cancel() }
        clients.removeAll()

        acceptSource?.cancel()
        acceptSource = nil

        if listeningFileDescriptor != -1 {
            close(listeningFileDescriptor)
            listeningFileDescriptor = -1
        }

        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptPendingClients() {
        guard listeningFileDescriptor != -1 else {
            return
        }

        while true {
            let clientFileDescriptor = accept(listeningFileDescriptor, nil, nil)

            if clientFileDescriptor == -1 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }

                return
            }

            do {
                try makeSocketNonBlocking(clientFileDescriptor)
                configureClient(fileDescriptor: clientFileDescriptor)
            } catch {
                close(clientFileDescriptor)
            }
        }
    }

    private func configureClient(fileDescriptor: Int32) {
        let clientID = UUID()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

        readSource.setEventHandler { [weak self] in
            self?.readAvailableData(from: clientID)
        }
        readSource.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if let client = self.clients[clientID] {
                close(client.fileDescriptor)
            } else {
                close(fileDescriptor)
            }
        }

        clients[clientID] = ClientConnection(
            id: clientID,
            fileDescriptor: fileDescriptor,
            readSource: readSource,
            role: nil
        )
        readSource.resume()

        send(.hello(BridgeHello()), to: clientID)
    }

    private func readAvailableData(from clientID: UUID) {
        guard var client = clients[clientID] else {
            return
        }

        var localBuffer = [UInt8](repeating: 0, count: 8_192)

        while true {
            let bytesRead = read(client.fileDescriptor, &localBuffer, localBuffer.count)

            if bytesRead > 0 {
                client.buffer.append(localBuffer, count: bytesRead)

                do {
                    let envelopes = try BridgeCodec.decodeLines(from: &client.buffer)
                    clients[clientID] = client

                    for envelope in envelopes {
                        if case let .command(command) = envelope {
                            handle(command, from: clientID)
                        }
                    }
                } catch {
                    removeClient(clientID)
                    return
                }

                continue
            }

            if bytesRead == 0 {
                removeClient(clientID)
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                clients[clientID] = client
                return
            }

            removeClient(clientID)
            return
        }
    }

    private func resetDemo(broadcastToAllClients: Bool) {
        scheduledItems.forEach { $0.cancel() }
        scheduledItems.removeAll()

        pendingApprovals.values.forEach { $0.timeoutItem.cancel() }
        pendingApprovals.removeAll()

        state = SessionState()
        let initialEvents = MockAgentScenario.initialEvents
        initialEvents.forEach { state.apply($0) }

        if broadcastToAllClients {
            broadcast(initialEvents.map(BridgeEnvelope.event))
        }

        for scheduled in MockAgentScenario.timeline(referenceDate: .now) {
            schedule(event: scheduled.event, after: scheduled.delay)
        }
    }

    private func handle(_ command: BridgeCommand, from clientID: UUID) {
        switch command {
        case let .registerClient(role):
            guard var client = clients[clientID] else {
                return
            }

            client.role = role
            clients[clientID] = client
            send(.response(.acknowledged), to: clientID)

        case .resetDemo:
            resetDemo(broadcastToAllClients: true)
            send(.response(.acknowledged), to: clientID)

        case let .resolvePermission(sessionID, approved):
            let hasPendingHook = pendingApprovals[sessionID] != nil
            let event: AgentEvent

            if approved {
                event = .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: sessionID,
                        summary: hasPendingHook
                            ? "Permission approved. Codex continued the command."
                            : "Permission approved. Agent resumed work.",
                        phase: .running,
                        timestamp: .now
                    )
                )

                if !hasPendingHook {
                    schedule(
                        event: .sessionCompleted(
                            SessionCompleted(
                                sessionID: sessionID,
                                summary: "Auth middleware patch applied after approval.",
                                timestamp: .now.addingTimeInterval(4)
                            )
                        ),
                        after: 4
                    )
                }
            } else {
                event = .sessionCompleted(
                    SessionCompleted(
                        sessionID: sessionID,
                        summary: hasPendingHook
                            ? "Permission denied in Vibe Island."
                            : "Permission denied. Review the session in the terminal.",
                        timestamp: .now
                    )
                )
            }

            emit(event)
            resolvePendingApproval(sessionID: sessionID, approved: approved)
            send(.response(.acknowledged), to: clientID)

        case let .answerQuestion(sessionID, answer):
            let resumeEvent = AgentEvent.activityUpdated(
                SessionActivityUpdated(
                    sessionID: sessionID,
                    summary: "Answered: \(answer)",
                    phase: .running,
                    timestamp: .now
                )
            )

            emit(resumeEvent)
            schedule(
                event: .sessionCompleted(
                    SessionCompleted(
                        sessionID: sessionID,
                        summary: "Slow query analysis finished after targeting \(answer.lowercased()).",
                        timestamp: .now.addingTimeInterval(4)
                    )
                ),
                after: 4
            )
            send(.response(.acknowledged), to: clientID)

        case let .processCodexHook(payload):
            handleCodexHook(payload, from: clientID)
        }
    }

    private func handleCodexHook(_ payload: CodexHookPayload, from clientID: UUID) {
        switch payload.hookEventName {
        case .sessionStart:
            let event = AgentEvent.sessionStarted(
                SessionStarted(
                    sessionID: payload.sessionID,
                    title: payload.sessionTitle,
                    tool: .codex,
                    summary: payload.implicitStartSummary,
                    timestamp: .now,
                    jumpTarget: payload.defaultJumpTarget
                )
            )

            emit(event)
            send(.response(.acknowledged), to: clientID)

        case .userPromptSubmit:
            ensureSessionExists(for: payload)
            let prompt = payload.promptPreview ?? "User submitted a prompt to Codex."
            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: "Prompt: \(prompt)",
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .preToolUse:
            ensureSessionExists(for: payload)

            let command = payload.commandPreview ?? "Bash command"
            guard hasApprovalObserver(excluding: clientID) else {
                emit(
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: payload.sessionID,
                            summary: "Running Bash: \(command)",
                            phase: .running,
                            timestamp: .now
                        )
                    )
                )
                send(.response(.acknowledged), to: clientID)
                return
            }

            pendingApprovals[payload.sessionID]?.timeoutItem.cancel()

            let approvalEvent = AgentEvent.permissionRequested(
                PermissionRequested(
                    sessionID: payload.sessionID,
                    request: PermissionRequest(
                        title: "Run Bash command",
                        summary: "Codex wants to run a shell command.",
                        affectedPath: payload.commandText ?? command,
                        primaryActionTitle: "Allow",
                        secondaryActionTitle: "Deny"
                    ),
                    timestamp: .now
                )
            )

            emit(approvalEvent)

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.resolveTimedOutApproval(
                    sessionID: payload.sessionID,
                    commandPreview: command
                )
            }

            pendingApprovals[payload.sessionID] = PendingApproval(
                clientID: clientID,
                timeoutItem: timeoutItem
            )
            queue.asyncAfter(deadline: .now() + approvalTimeout, execute: timeoutItem)

        case .postToolUse:
            ensureSessionExists(for: payload)
            let command = payload.commandPreview ?? "Bash command"
            let responsePreview = payload.toolResponsePreview
            let summary = responsePreview.map { "Bash finished: \(command) · \($0)" } ?? "Bash finished: \(command)"

            emit(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: payload.sessionID,
                        summary: summary,
                        phase: .running,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)

        case .stop:
            ensureSessionExists(for: payload)
            let summary = payload.assistantMessagePreview ?? "Codex completed the turn."

            emit(
                .sessionCompleted(
                    SessionCompleted(
                        sessionID: payload.sessionID,
                        summary: summary,
                        timestamp: .now
                    )
                )
            )
            send(.response(.acknowledged), to: clientID)
        }
    }

    private func hasApprovalObserver(excluding clientID: UUID) -> Bool {
        if clients.values.contains(where: { $0.id != clientID && $0.role == .observer }) {
            return true
        }

        return clients.values.contains(where: { $0.id != clientID })
    }

    private func ensureSessionExists(for payload: CodexHookPayload) {
        guard state.session(id: payload.sessionID) == nil else {
            return
        }

        emit(
            .sessionStarted(
                SessionStarted(
                    sessionID: payload.sessionID,
                    title: payload.sessionTitle,
                    tool: .codex,
                    summary: payload.implicitStartSummary,
                    timestamp: .now,
                    jumpTarget: payload.defaultJumpTarget
                )
            )
        )
    }

    private func resolvePendingApproval(sessionID: String, approved: Bool) {
        guard let pendingApproval = pendingApprovals.removeValue(forKey: sessionID) else {
            return
        }

        pendingApproval.timeoutItem.cancel()

        let response: BridgeResponse
        if approved {
            response = .acknowledged
        } else {
            response = .codexHookDirective(.deny(reason: "Permission denied in Vibe Island."))
        }

        send(.response(response), to: pendingApproval.clientID)
    }

    private func resolveTimedOutApproval(sessionID: String, commandPreview: String) {
        guard let pendingApproval = pendingApprovals.removeValue(forKey: sessionID) else {
            return
        }

        emit(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: sessionID,
                    summary: "Approval timed out. Codex continued Bash: \(commandPreview)",
                    phase: .running,
                    timestamp: .now
                )
            )
        )

        send(.response(.acknowledged), to: pendingApproval.clientID)
    }

    private func emit(_ event: AgentEvent) {
        state.apply(event)
        broadcast([.event(event)])
    }

    private func schedule(event: AgentEvent, after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.emit(event)
        }

        scheduledItems.append(item)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func send(_ envelope: BridgeEnvelope, to clientID: UUID) {
        guard let client = clients[clientID] else {
            return
        }

        do {
            let data = try BridgeCodec.encodeLine(envelope)
            try writeAll(data, to: client.fileDescriptor)
        } catch {
            removeClient(clientID)
        }
    }

    private func broadcast(_ envelopes: [BridgeEnvelope]) {
        let clientIDs = Array(clients.keys)

        for clientID in clientIDs {
            for envelope in envelopes {
                send(envelope, to: clientID)
            }
        }
    }

    private func removeClient(_ clientID: UUID) {
        guard let client = clients.removeValue(forKey: clientID) else {
            return
        }

        let pendingSessionIDs = pendingApprovals.compactMap { entry -> String? in
            let (sessionID, pendingApproval) = entry
            return pendingApproval.clientID == clientID ? sessionID : nil
        }

        for sessionID in pendingSessionIDs {
            pendingApprovals[sessionID]?.timeoutItem.cancel()
            pendingApprovals.removeValue(forKey: sessionID)
        }

        client.readSource.cancel()
    }
}
