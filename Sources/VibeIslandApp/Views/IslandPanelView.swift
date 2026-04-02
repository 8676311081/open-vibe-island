import SwiftUI
import VibeIslandCore

// MARK: - Animations

private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
private let popAnimation = Animation.spring(response: 0.3, dampingFraction: 0.5)

// MARK: - Main island view

struct IslandPanelView: View {
    private static let maxVisibleSessionRows = 6

    var model: AppModel

    @Namespace private var notchNamespace
    @State private var isHovering = false
    @State private var hoveredSessionID: String?

    private var isOpened: Bool {
        model.notchStatus == .opened
    }

    private var isPopping: Bool {
        model.notchStatus == .popping
    }

    private var closedSpotlightSession: AgentSession? {
        model.surfacedSessions.first(where: { $0.phase.requiresAttention })
            ?? model.surfacedSessions.first(where: { $0.phase == .running })
            ?? model.surfacedSessions.first
    }

    private var hasClosedPresence: Bool {
        model.liveSessionCount > 0
    }

    /// Whether any session has activity worth showing in the closed notch
    private var hasClosedActivity: Bool {
        guard let session = closedSpotlightSession else {
            return false
        }
        return session.phase == .running || session.phase.requiresAttention
    }

    private var countBadgeWidth: CGFloat {
        let digits = max(1, "\(model.liveSessionCount)".count)
        return CGFloat(18 + max(0, digits - 1) * 7)
    }

    private var expansionWidth: CGFloat {
        guard hasClosedPresence else { return 0 }
        let leftWidth = sideWidth + 8 + (closedSpotlightSession?.phase.requiresAttention == true ? 18 : 0)
        let rightWidth = max(sideWidth, countBadgeWidth)
        let hasPending = closedSpotlightSession?.phase.requiresAttention == true
        return leftWidth + rightWidth + 16 + (hasPending ? 6 : 0)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchHeight - 12) + 10
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.clear

                notchContent(availableSize: geometry.size)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func notchContent(availableSize: CGSize) -> some View {
        let outerHorizontalPadding: CGFloat = isOpened ? 28 : 0
        let outerBottomPadding: CGFloat = isOpened ? 14 : 0
        let openedWidth = max(0, availableSize.width - outerHorizontalPadding)
        let closedWidth = availableSize.width
        let currentWidth = isOpened ? openedWidth : closedWidth
        let currentHeight = isOpened ? max(closedNotchHeight, availableSize.height - outerBottomPadding) : availableSize.height

        VStack(spacing: 0) {
            headerRow
                .frame(height: closedNotchHeight)

            if isOpened {
                openedContent
                    .frame(width: openedWidth - 24)
                    .frame(maxHeight: currentHeight - closedNotchHeight - 12, alignment: .top)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .top)
        .padding(.horizontal, isOpened ? 14 : 0)
        .padding(.bottom, isOpened ? 14 : 0)
        .background(surfaceFill)
        .clipShape(
            NotchShape(
                topCornerRadius: isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius,
                bottomCornerRadius: isOpened ? NotchShape.openedBottomRadius : NotchShape.closedBottomRadius
            )
        )
        .overlay(alignment: .top) {
            // Black strip to blend with physical notch at the very top
            Rectangle()
                .fill(Color.black)
                .frame(height: 1)
                .padding(.horizontal, isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius)
        }
        .overlay {
            NotchShape(
                topCornerRadius: isOpened ? NotchShape.openedTopRadius : NotchShape.closedTopRadius,
                bottomCornerRadius: isOpened ? NotchShape.openedBottomRadius : NotchShape.closedBottomRadius
            )
            .stroke(Color.white.opacity(isOpened ? 0.07 : 0.04), lineWidth: 1)
        }
        .shadow(
            color: (isOpened || isHovering) ? .black.opacity(0.46) : .clear,
            radius: 16,
            y: 8
        )
        .animation(isOpened ? openAnimation : closeAnimation, value: model.notchStatus)
        .animation(.smooth, value: hasClosedPresence)
        .animation(.smooth, value: expansionWidth)
        .animation(popAnimation, value: isPopping)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if !isOpened {
                model.notchOpen(reason: .click)
            }
        }
    }

    // MARK: - Closed state

    private var closedNotchWidth: CGFloat {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })?.notchSize.width ?? 224
    }

    private var closedNotchHeight: CGFloat {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })?.notchSize.height ?? 38
    }

    // MARK: - Header row (shared between closed and opened)

    @ViewBuilder
    private var headerRow: some View {
        if isOpened {
            openedHeaderContent
                .frame(height: closedNotchHeight)
        } else {
            HStack(spacing: 0) {
                if hasClosedPresence {
                    HStack(spacing: 4) {
                        VibeIslandIcon(size: 14, isAnimating: hasClosedActivity)
                            .matchedGeometryEffect(id: "island-icon", in: notchNamespace, isSource: true)

                        if closedSpotlightSession?.phase.requiresAttention == true {
                            AttentionIndicator(
                                size: 14,
                                color: phaseColor(closedSpotlightSession?.phase ?? .running)
                            )
                        }
                    }
                    .frame(width: sideWidth + 8 + (closedSpotlightSession?.phase.requiresAttention == true ? 18 : 0))
                }

                if !hasClosedPresence {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: closedNotchWidth - 20)
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: closedNotchWidth - NotchShape.closedTopRadius + (isPopping ? 18 : 0))
                }

                if hasClosedPresence {
                    ClosedCountBadge(
                        liveCount: model.liveSessionCount,
                        tint: closedSpotlightSession?.phase.requiresAttention == true ? .orange : (hasClosedActivity ? .mint : .white.opacity(0.7))
                    )
                    .matchedGeometryEffect(id: "right-indicator", in: notchNamespace, isSource: true)
                    .frame(width: max(sideWidth, countBadgeWidth))
                }
            }
            .frame(height: closedNotchHeight)
        }
    }

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            openedUsageSummary
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                headerIconButton(
                    systemName: model.isSoundMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tint: model.isSoundMuted ? .orange.opacity(0.92) : .white.opacity(0.62)
                ) {
                    model.toggleSoundMuted()
                }

                headerIconButton(systemName: "gearshape.fill", tint: .white.opacity(0.62)) {
                    model.showControlCenter()
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.top, 2)
    }

    private func headerIconButton(
        systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var openedContent: some View {
        VStack(spacing: 0) {
            if model.surfacedSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No open terminal sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text(model.recentSessions.isEmpty
                ? "Start Codex in your terminal"
                : "Recent sessions remain in Control Center until the terminal is open again")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let presentation = sessionListPresentation(at: context.date)

            VStack(spacing: 4) {
                ForEach(presentation.visibleSessions) { session in
                    IslandSessionRow(
                        session: session,
                        isHighlighted: session.id == hoveredSessionID,
                        onHoverChange: { isHovering in
                            hoveredSessionID = isHovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
                        },
                        onJump: { model.jumpToSession(session) },
                        onApprove: { model.approvePermission(for: session.id, approved: $0) },
                        onAnswer: { model.answerQuestion(for: session.id, answer: $0) }
                    )
                }

                if presentation.hiddenSessionCount > 0 {
                    HiddenSessionsRow(hiddenSessionCount: presentation.hiddenSessionCount)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var displayedSessions: [AgentSession] {
        model.surfacedSessions
    }

    private func sessionListPresentation(at referenceDate: Date) -> SessionListPresentation {
        let sessions = displayedSessions
        guard sessions.count > Self.maxVisibleSessionRows else {
            return SessionListPresentation(visibleSessions: sessions, hiddenSessionCount: 0)
        }

        let activeSessions = sessions.filter { $0.islandPresence(at: referenceDate) != .inactive }
        let inactiveSessions = sessions.filter { $0.islandPresence(at: referenceDate) == .inactive }
        let contentSlots = max(0, Self.maxVisibleSessionRows - 1)

        var visibleSessions = Array(activeSessions.prefix(contentSlots))

        if visibleSessions.count < contentSlots {
            let remainingSlots = contentSlots - visibleSessions.count
            visibleSessions.append(contentsOf: inactiveSessions.prefix(remainingSlots))
        }

        let hiddenSessionCount = max(0, sessions.count - visibleSessions.count)
        return SessionListPresentation(
            visibleSessions: visibleSessions,
            hiddenSessionCount: hiddenSessionCount
        )
    }

    // MARK: - Helpers

    private var surfaceFill: some ShapeStyle {
        Color.black
    }

    private func phaseColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .running: .mint
        case .waitingForApproval: .orange
        case .waitingForAnswer: .yellow
        case .completed: .blue
        }
    }

    @ViewBuilder
    private var openedUsageSummary: some View {
        let providers = openedUsageProviders

        if providers.isEmpty == false {
            HStack(spacing: 8) {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 {
                        usageSeparator(opacity: 0.2)
                    }

                    usageProviderView(provider)
                }
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                Text("Vibe Island")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Usage waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .lineLimit(1)
        }
    }

    private var openedUsageProviders: [UsageProviderPresentation] {
        var providers: [UsageProviderPresentation] = []

        if let snapshot = model.claudeUsageSnapshot,
           snapshot.isEmpty == false {
            var windows: [UsageWindowPresentation] = []

            if let fiveHour = snapshot.fiveHour {
                windows.append(
                    UsageWindowPresentation(
                        id: "claude-5h",
                        label: "5h",
                        usedPercentage: fiveHour.usedPercentage,
                        resetsAt: fiveHour.resetsAt
                    )
                )
            }

            if let sevenDay = snapshot.sevenDay {
                windows.append(
                    UsageWindowPresentation(
                        id: "claude-7d",
                        label: "7d",
                        usedPercentage: sevenDay.usedPercentage,
                        resetsAt: sevenDay.resetsAt
                    )
                )
            }

            if windows.isEmpty == false {
                providers.append(
                    UsageProviderPresentation(
                        id: "claude",
                        title: "Claude",
                        windows: windows
                    )
                )
            }
        }

        if let snapshot = model.codexUsageSnapshot,
           snapshot.isEmpty == false {
            let windows = snapshot.windows.map { window in
                UsageWindowPresentation(
                    id: "codex-\(window.key)",
                    label: window.label,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt
                )
            }

            if windows.isEmpty == false {
                providers.append(
                    UsageProviderPresentation(
                        id: "codex",
                        title: "Codex",
                        windows: windows
                    )
                )
            }
        }

        return providers
    }

    private func usageProviderView(_ provider: UsageProviderPresentation) -> some View {
        HStack(spacing: 8) {
            Text(provider.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            ForEach(Array(provider.windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 {
                    usageSeparator(opacity: 0.16)
                }

                usageWindowView(window: window)
            }
        }
    }

    private func usageWindowView(window: UsageWindowPresentation) -> some View {
        HStack(spacing: 4) {
            Text(window.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Text("\(window.roundedUsedPercentage)%")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(usageColor(for: window.usedPercentage))

            if let resetsAt = window.resetsAt,
               let remaining = remainingDurationString(until: resetsAt) {
                Text(remaining)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func usageSeparator(opacity: Double) -> some View {
        Text("|")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(opacity))
    }

    private func headerPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private func usageColor(for percentage: Double) -> Color {
        switch percentage {
        case 90...:
            .red.opacity(0.95)
        case 70..<90:
            .orange.opacity(0.95)
        default:
            .green.opacity(0.95)
        }
    }

    private func remainingDurationString(until date: Date) -> String? {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            return nil
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated

        if interval >= 86_400 {
            formatter.allowedUnits = [.day]
            formatter.maximumUnitCount = 1
        } else if interval >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
        } else {
            formatter.allowedUnits = [.minute]
            formatter.maximumUnitCount = 1
        }

        return formatter.string(from: interval)
    }
}

private struct SessionListPresentation {
    let visibleSessions: [AgentSession]
    let hiddenSessionCount: Int
}

private struct UsageProviderPresentation: Identifiable {
    let id: String
    let title: String
    let windows: [UsageWindowPresentation]
}

private struct UsageWindowPresentation: Identifiable {
    let id: String
    let label: String
    let usedPercentage: Double
    let resetsAt: Date?

    var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

// MARK: - Session row (opened state)

private struct IslandSessionRow: View {
    let session: AgentSession
    let isHighlighted: Bool
    let onHoverChange: (Bool) -> Void
    let onJump: () -> Void
    let onApprove: (Bool) -> Void
    let onAnswer: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            rowBody(referenceDate: context.date)
        }
    }

    private func rowBody(referenceDate: Date) -> some View {
        let presence = session.islandPresence(at: referenceDate)
        let showsExpandedContent = presence != .inactive

        return VStack(alignment: .leading, spacing: 10) {
            Button(action: handlePrimaryTap) {
                HStack(alignment: .top, spacing: 14) {
                    statusDot(for: presence)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(session.spotlightHeadlineText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(headlineColor(for: presence))
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            HStack(spacing: 6) {
                                compactBadge(session.tool.displayName, presence: presence)
                                if let terminalBadge = session.spotlightTerminalBadge {
                                    compactBadge(terminalBadge, presence: presence)
                                }
                                compactBadge(session.spotlightAgeBadge, presence: presence)
                            }
                        }

                        if showsExpandedContent,
                           let promptLine = session.spotlightPromptLineText {
                            Text(promptLine)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }

                        if showsExpandedContent,
                           let activityLine = session.spotlightActivityLineText {
                            Text(activityLine)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(activityColor(for: presence).opacity(0.94))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if isHighlighted {
                actionRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isHighlighted ? Color.white.opacity(0.05) : Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isHighlighted ? .white.opacity(0.24) : .white.opacity(0.04))
        )
        .shadow(color: isHighlighted ? .black.opacity(0.24) : .clear, radius: 12, y: 8)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(isHighlighted ? 0 : 0.02))
                .frame(height: 1),
            alignment: .bottom
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover(perform: onHoverChange)
    }

    private func statusDot(for presence: IslandSessionPresence) -> some View {
        Circle()
            .fill(statusTint(for: presence))
            .frame(width: 9, height: 9)
            .padding(.top, 6)
    }

    @ViewBuilder
    private var actionRow: some View {
        if let request = session.permissionRequest {
            HStack(spacing: 8) {
                Text(request.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(request.secondaryActionTitle) { onApprove(false) }
                    .buttonStyle(IslandCompactButtonStyle(tint: .secondary))
                Button(request.primaryActionTitle) { onApprove(true) }
                    .buttonStyle(IslandCompactButtonStyle(tint: .orange))
            }
        } else if let prompt = session.questionPrompt {
            HStack(spacing: 8) {
                Text(prompt.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 8)
                ForEach(prompt.options.prefix(2), id: \.self) { option in
                    Button(option) { onAnswer(option) }
                        .buttonStyle(IslandCompactButtonStyle(tint: .secondary))
                }
            }
        }
    }

    private func handlePrimaryTap() {
        onJump()
    }

    private func compactBadge(
        _ title: String,
        presence: IslandSessionPresence
    ) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(badgeTextColor(for: presence))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Color(red: 0.14, green: 0.14, blue: 0.15), in: Capsule())
    }

    private func headlineColor(for presence: IslandSessionPresence) -> Color {
        presence == .inactive ? .white.opacity(0.78) : .white
    }

    private func badgeTextColor(for presence: IslandSessionPresence) -> Color {
        presence == .inactive ? .white.opacity(0.42) : .white.opacity(0.56)
    }

    private func statusTint(for presence: IslandSessionPresence) -> Color {
        switch presence {
        case .running:
            Color(red: 0.34, green: 0.61, blue: 0.99)
        case .active:
            Color(red: 0.29, green: 0.86, blue: 0.46)
        case .inactive:
            .white.opacity(0.38)
        }
    }

    private func activityColor(for presence: IslandSessionPresence) -> Color {
        switch session.spotlightActivityTone {
        case .attention:
            .orange.opacity(0.94)
        case .live:
            statusTint(for: presence)
        case .idle:
            .white.opacity(0.46)
        case .ready:
            presence == .inactive ? .white.opacity(0.46) : statusTint(for: presence)
        }
    }
}

private struct HiddenSessionsRow: View {
    let hiddenSessionCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(.white.opacity(0.28))
                .frame(width: 9, height: 9)
                .padding(.top, 2)

            Text("\(hiddenSessionCount) session\(hiddenSessionCount == 1 ? "" : "s") hidden")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.04))
        )
    }
}

// MARK: - Compact button style

private struct IslandCompactButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint == .secondary ? .white.opacity(0.7) : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (tint == .secondary ? Color.white.opacity(0.08) : tint.opacity(0.15)),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Vibe Island icon (left side of closed notch)

private struct VibeIslandIcon: View {
    let size: CGFloat
    var isAnimating: Bool = false
    var tint: Color = .mint

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                iconBlock
                iconBlock
            }
            HStack(spacing: 2) {
                iconBlock
                iconBlock
            }
        }
        .frame(width: size, height: size)
    }

    private var iconBlock: some View {
        RoundedRectangle(cornerRadius: 1.8, style: .continuous)
            .fill(tint.opacity(isAnimating ? 1.0 : 0.82))
    }
}

// MARK: - Attention indicator (permission/question dot)

private struct AttentionIndicator: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size * 0.75, weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - Closed count badge (right side of closed notch)

private struct ClosedCountBadge: View {
    let liveCount: Int
    let tint: Color

    var body: some View {
        Text("\(liveCount)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(red: 0.14, green: 0.14, blue: 0.15), in: Capsule())
    }
}

// MARK: - Menu bar content (unchanged)

struct MenuBarContentView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vibe Island OSS")
                .font(.headline)
            Text("\(model.liveSessionCount) live · \(model.liveAttentionCount) attention")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Control Center") {
                model.showControlCenter()
            }

            Text(model.acceptanceStatusTitle)
                .font(.subheadline.weight(.semibold))
            Text(model.acceptanceStatusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(model.isOverlayVisible ? "Hide Island Overlay" : "Show Island Overlay") {
                model.toggleOverlay()
            }

            Divider()

            Text(model.codexHookStatusTitle)
                .font(.subheadline.weight(.semibold))
            Text(model.codexHookStatusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Refresh Codex Hook Status") {
                model.refreshCodexHookStatus()
            }

            if model.codexHooksInstalled {
                Button("Uninstall Codex Hooks") {
                    model.uninstallCodexHooks()
                }
            } else {
                Button("Install Codex Hooks") {
                    model.installCodexHooks()
                }
                .disabled(model.hooksBinaryURL == nil)
            }

            if let session = model.focusedSession {
                Divider()
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                Text(session.spotlightPrimaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let currentTool = session.spotlightCurrentToolLabel {
                    Text("Live tool: \(currentTool)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let trackingLabel = session.spotlightTrackingLabel {
                    Text("Tracking: \(trackingLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
