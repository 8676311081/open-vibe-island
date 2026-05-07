import AppKit
import OpenIslandCore
import SwiftUI

struct LLMSpendSettingsPane: View {
    var model: AppModel

    @State private var portFieldText: String = ""
    @State private var openAIUpstreamText: String = ""
    @State private var anthropicUpstreamText: String = ""
    @State private var upstreamErrorKey: String?
    @State private var copiedKey: String?
    @State private var showStatsSheet: Bool = false
    @State private var showRTKConfirmSheet: Bool = false
    @State private var agentSnapshots: [AgentUsageSnapshot] = []
    /// DeepSeek balance snapshot, read from
    /// `LLMProxyCoordinator.deepseekBalance` actor at appear time
    /// and (in the future) on a manual refresh button. Nil while
    /// the cache is empty or the credential is missing.
    @State private var deepseekBalanceSnapshot: DeepSeekBalanceSnapshot?

    private var lang: LanguageManager { model.lang }

    private static let exportLines = [
        "export ANTHROPIC_BASE_URL=http://127.0.0.1:9710",
        "export OPENAI_BASE_URL=http://127.0.0.1:9710",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                detailedStatsButton
                header
                statusRow
                if showOnboarding {
                    onboardingCard
                }
                if !todayBreakdown.isEmpty {
                    breakdownSection
                }
                if !todayModelBreakdown.isEmpty {
                    modelBreakdownSection
                }
                if let warning = mostRecentWarning {
                    duplicateWarningSection(warning)
                }
                controlsSection
                upstreamsSection
                compressionSection
                agentsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(lang.t("settings.tab.llmSpend"))
        .onAppear {
            syncFields()
            // Pull current RTK status fresh whenever the user lands on
            // this pane — handles the "user manually deleted the
            // binary outside the app" case without waiting for the
            // 30 s watchdog tick.
            model.hooks.refreshRtkStatus()
            Task { @MainActor in await loadAgentUsages() }
            Task { @MainActor in await loadDeepseekBalance() }
        }
        .onChange(of: model.llmProxyPort) { _, _ in syncFields() }
        .onChange(of: model.llmProxyOpenAIUpstream) { _, _ in syncFields() }
        .onChange(of: model.llmProxyAnthropicUpstream) { _, _ in syncFields() }
        .sheet(isPresented: $showStatsSheet) {
            LLMSpendStatsView(model: model)
        }
        .sheet(isPresented: $showRTKConfirmSheet) {
            rtkConfirmSheet
        }
    }

    private var detailedStatsButton: some View {
        HStack {
            Spacer()
            Button {
                showStatsSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                    Text(lang.t("settings.llmSpend.viewDetailedStats"))
                }
            }
            .controlSize(.regular)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.t("settings.llmSpend.title"))
                .font(.title2.weight(.semibold))
            Text(lang.t("settings.llmSpend.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        // Three-port status row replaces the legacy single
        // "proxy running on 9710 · today $0.02" line. Each card
        // surfaces one ProviderGroup with a shape-appropriate
        // metric — see BillingShape for why we don't unify on USD.
        // Card order matches ProviderGroup.allCases (stable):
        // officialClaude → deepseek → thirdParty.
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(ProviderGroup.allCases, id: \.self) { group in
                    groupStatusCard(for: group)
                }
            }
            // Cross-group total still useful as a glance — kept on
            // its own row instead of the right-side pill it used to
            // occupy. Less prominent than per-group cards because
            // the unified "today total" can mix subscription tokens
            // with metered USD, which doesn't really sum.
            HStack {
                Spacer()
                todayPill
            }
        }
    }

    private func groupStatusCard(for group: ProviderGroup) -> some View {
        let bucket = todayGroupBucket(for: group)
        let port = group.defaultLoopbackPort
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLLMProxyRunning ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text("\(port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(lang.t(groupTitleKey(for: group)))
                    .font(.caption.weight(.semibold))
            }
            // Primary metric. BillingShape decides what's
            // foregrounded — subscription groups suppress USD,
            // metered groups suppress raw token counts as the
            // headline. Empty / unknown groups show "—".
            Text(groupHeadlineMetric(group: group, bucket: bucket))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(lang.t("settings.llmSpend.group.todayLabel"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Per-group detail strip. Only `officialClaude` has one
            // so far — the 5h subscription window from
            // ClaudeUsageLoader's statusline cache. DeepSeek's
            // balance line and third-party billing-shape rows land
            // in subsequent commits.
            if let detail = groupDetailLine(for: group) {
                Divider().padding(.top, 4)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Optional one-line subtitle under a card's headline metric.
    /// Per-shape detail rows: subscription window for
    /// officialClaude, account balance for deepseek. Third-party
    /// stays blank for now — its detail rows are per-profile
    /// adapters in a follow-up commit.
    private func groupDetailLine(for group: ProviderGroup) -> String? {
        switch group {
        case .officialClaude:
            return officialClaudeDetailLine()
        case .deepseek:
            return deepseekDetailLine()
        case .thirdParty:
            return nil
        }
    }

    private func officialClaudeDetailLine() -> String? {
        guard let snapshot = model.claudeUsageSnapshot,
              let window = snapshot.fiveHour
        else {
            return nil
        }
        let pct = window.roundedUsedPercentage
        let baseLabel = lang.t("settings.llmSpend.group.officialClaude.fiveHour")
        guard let resetsAt = window.resetsAt else {
            return "\(baseLabel) \(pct)%"
        }
        let interval = resetsAt.timeIntervalSinceNow
        if interval <= 0 {
            return "\(baseLabel) \(pct)%"
        }
        let resetsIn = formatRelativeDuration(seconds: Int(interval))
        let template = lang.t("settings.llmSpend.group.officialClaude.fiveHour.template")
        return template
            .replacingOccurrences(of: "{percent}", with: "\(pct)")
            .replacingOccurrences(of: "{resetIn}", with: resetsIn)
    }

    private func deepseekDetailLine() -> String? {
        guard let snapshot = deepseekBalanceSnapshot else {
            return nil
        }
        // Format with two decimals — DeepSeek balances are USD
        // values that benefit from the precision (a $0.012 spend
        // matters when the total is $14.20).
        let amount = String(format: "%.2f", snapshot.totalBalance)
        let template: String
        if !snapshot.isAvailable {
            template = lang.t("settings.llmSpend.group.deepseek.balance.unavailable")
        } else {
            template = lang.t("settings.llmSpend.group.deepseek.balance.template")
        }
        return template
            .replacingOccurrences(of: "{amount}", with: amount)
            .replacingOccurrences(of: "{currency}", with: snapshot.currency)
    }

    /// Format a positive duration as "1h 23m" / "47m" / "30s".
    /// Kept inline because it's only used by the quota subtitle —
    /// global helpers can come later if more cards need it.
    private func formatRelativeDuration(seconds total: Int) -> String {
        if total >= 3600 {
            let h = total / 3600
            let m = (total % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if total >= 60 {
            return "\(total / 60)m"
        }
        return "\(total)s"
    }

    /// Pull today's per-group totals out of the snapshot. Each
    /// `LLMDayBucket` carries `groupTurns / groupCosts /
    /// groupTokens` (added in the stats-attribution commit); we
    /// sum those across all clients so the cards represent the
    /// listener-level activity for the day.
    private struct GroupBucket {
        var turns: Int = 0
        var tokens: Int = 0
        var costUSD: Double = 0
        var hasCost: Bool = false  // any client recorded a cost vs unpriced-only
    }

    private func todayGroupBucket(for group: ProviderGroup) -> GroupBucket {
        var out = GroupBucket()
        let groupKey = group.rawValue
        for bucket in todayBuckets.values {
            out.turns += bucket.groupTurns[groupKey] ?? 0
            out.tokens += bucket.groupTokens[groupKey] ?? 0
            if let c = bucket.groupCosts[groupKey] {
                out.costUSD += c
                out.hasCost = true
            }
        }
        return out
    }

    private func groupTitleKey(for group: ProviderGroup) -> String {
        switch group {
        case .officialClaude: return "settings.llmSpend.group.officialClaude"
        case .deepseek: return "settings.llmSpend.group.deepseek"
        case .thirdParty: return "settings.llmSpend.group.thirdParty"
        }
    }

    /// Choose the right headline number for a card based on the
    /// group's billing shape. Subscription windows show tokens
    /// (Claude Max isn't priced per-request); metered groups show
    /// USD; mixed third-party falls back to whichever signal we
    /// actually have.
    private func groupHeadlineMetric(
        group: ProviderGroup,
        bucket: GroupBucket
    ) -> String {
        if bucket.turns == 0 {
            return "—"
        }
        switch group {
        case .officialClaude:
            // Subscription — token count is the load signal, USD
            // makes no sense.
            return formattedTokens(bucket.tokens)
        case .deepseek, .thirdParty:
            return bucket.hasCost
                ? LLMSpendFormatting.formatCost(bucket.costUSD)
                : formattedTokens(bucket.tokens)
        }
    }

    private var todayPill: some View {
        let totals = totalsForToday()
        return HStack(spacing: 6) {
            Text(lang.t("settings.llmSpend.todayTotal"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(totals.costDisplay)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(totals.hasUnpriced ? Color.orange : Color.primary)
                .help(totals.hasUnpriced ? lang.t("settings.llmSpend.unpricedTooltip") : "")
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.t("settings.llmSpend.byClient"))
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(todayBreakdown, id: \.client) { entry in
                    breakdownRow(entry)
                    if entry.client != todayBreakdown.last?.client {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func breakdownRow(_ entry: BreakdownEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.client.displayName)
                .font(.subheadline.weight(.medium))
                .frame(width: 110, alignment: .leading)

            Text("\(entry.bucket.turns) \(lang.t("settings.llmSpend.client.turns"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text("\(formattedTokens(entry.bucket.tokensIn + entry.bucket.tokensOut)) \(lang.t("settings.llmSpend.client.tokens"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.costDisplay)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.hasUnpriced ? Color.orange : Color.primary)
                .help(entry.hasUnpriced ? lang.t("settings.llmSpend.unpricedTooltip") : "")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    // MARK: - Model breakdown

    private struct ModelBreakdownEntry {
        let modelID: String
        let displayName: String
        let turns: Int
        let cost: Double
        let isUnpriced: Bool

        var costDisplay: String {
            if isUnpriced { return "—" }
            return LLMSpendFormatting.formatCost(cost)
        }
    }

    private var todayModelBreakdown: [ModelBreakdownEntry] {
        var byModel: [String: (turns: Int, cost: Double, isUnpriced: Bool)] = [:]
        for bucket in todayBuckets.values where bucket.turns > 0 {
            for (modelID, mTurns) in bucket.modelTurns where mTurns > 0 {
                let mCost = bucket.modelCosts[modelID] ?? 0
                let hasCost = bucket.modelCosts.keys.contains(modelID)
                var entry = byModel[modelID] ?? (0, 0, false)
                entry.turns += mTurns
                entry.cost += mCost
                entry.isUnpriced = !hasCost && mCost == 0
                byModel[modelID] = entry
            }
        }
        return byModel
            .map { id, val in
                ModelBreakdownEntry(
                    modelID: id,
                    displayName: id, // raw ID is concise and recognizable
                    turns: val.turns,
                    cost: val.cost,
                    isUnpriced: val.isUnpriced
                )
            }
            .sorted { $0.cost > $1.cost }
    }

    private var modelBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.t("settings.llmSpend.byModel"))
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(todayModelBreakdown.enumerated()), id: \.element.modelID) { index, entry in
                    modelBreakdownRow(entry)
                    if index < todayModelBreakdown.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func modelBreakdownRow(_ entry: ModelBreakdownEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.displayName)
                .font(.subheadline.weight(.medium))
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)

            Text("\(entry.turns) \(lang.t("settings.llmSpend.client.turns"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.costDisplay)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.isUnpriced ? Color.orange : Color.primary)
                .help(entry.isUnpriced ? lang.t("settings.llmSpend.unpricedTooltip") : "")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    private func duplicateWarningSection(_ warning: LastWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("settings.llmSpend.lastWarning"))
                    .font(.subheadline.weight(.semibold))
                Text(String(
                    format: lang.t("settings.llmSpend.lastWarningTemplate"),
                    warning.toolName,
                    warning.formattedTime
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.t("settings.llmSpend.controls"))
                .font(.headline)

            HStack(spacing: 10) {
                Button(model.isLLMProxyRunning
                       ? lang.t("settings.llmSpend.stopProxy")
                       : lang.t("settings.llmSpend.startProxy")) {
                    model.toggleLLMProxy()
                }

                Spacer()

                Button(lang.t("settings.llmSpend.clearToday"), role: .destructive) {
                    model.clearTodayLLMStats()
                }
                .disabled(todayBreakdown.isEmpty)
            }

            HStack(spacing: 10) {
                Text(lang.t("settings.llmSpend.port"))
                    .font(.subheadline)
                TextField("9710", text: $portFieldText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { applyPort() }
                Button(lang.t("settings.llmSpend.applyPort")) {
                    applyPort()
                }
                .disabled(portFieldText == String(model.llmProxyPort) || parsedPort() == nil)
                Spacer()
            }
        }
    }

    private var upstreamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.t("settings.llmSpend.upstreams"))
                .font(.headline)
            Text(lang.t("settings.llmSpend.upstreamsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            upstreamRow(
                label: "OpenAI",
                placeholder: LLMProxyCoordinator.defaultOpenAIUpstream,
                text: $openAIUpstreamText,
                currentValue: model.llmProxyOpenAIUpstream,
                apply: {
                    if !model.setLLMProxyOpenAIUpstream(openAIUpstreamText) {
                        upstreamErrorKey = "openai"
                    } else {
                        upstreamErrorKey = nil
                    }
                },
                showError: upstreamErrorKey == "openai"
            )

            upstreamRow(
                label: "Anthropic",
                placeholder: LLMProxyCoordinator.defaultAnthropicUpstream,
                text: $anthropicUpstreamText,
                currentValue: model.llmProxyAnthropicUpstream,
                apply: {
                    if !model.setLLMProxyAnthropicUpstream(anthropicUpstreamText) {
                        upstreamErrorKey = "anthropic"
                    } else {
                        upstreamErrorKey = nil
                    }
                },
                showError: upstreamErrorKey == "anthropic"
            )
        }
    }

    private func upstreamRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        currentValue: URL,
        apply: @escaping () -> Void,
        showError: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.subheadline)
                    .frame(width: 80, alignment: .leading)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit(apply)
                Button(lang.t("settings.llmSpend.applyPort"), action: apply)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces) == currentValue.absoluteString
                              || text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if showError {
                Text(lang.t("settings.llmSpend.upstreamInvalid"))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 90)
            }
        }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.green)
                Text(lang.t("settings.llmSpend.onboardingTitle"))
                    .font(.headline)
            }
            Text(lang.t("settings.llmSpend.onboardingBody"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(exportLinesForCurrentPort(), id: \.self) { line in
                    exportRow(line)
                }
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func exportRow(_ line: String) -> some View {
        HStack(spacing: 8) {
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
            Button(copiedKey == line
                   ? lang.t("settings.llmSpend.copied")
                   : lang.t("settings.llmSpend.copy")) {
                copy(line)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Derived data

    private var todayKey: String {
        LLMStatsStore.dayKey(for: Date())
    }

    private var todayBuckets: [String: LLMDayBucket] {
        model.llmStatsSnapshot.days[todayKey] ?? [:]
    }

    private struct BreakdownEntry {
        let client: LLMClient
        let bucket: LLMDayBucket
        var hasUnpriced: Bool { bucket.unpricedTurns > 0 }
        var costDisplay: String {
            if bucket.turns > 0, bucket.unpricedTurns == bucket.turns {
                return "—"
            }
            let prefix = hasUnpriced ? "~" : ""
            return prefix + LLMSpendFormatting.formatCost(bucket.costUsd)
        }
    }

    private var todayBreakdown: [BreakdownEntry] {
        let order: [LLMClient] = [.claudeCode, .codex, .cursor, .unknown]
        return order.compactMap { client in
            guard let bucket = todayBuckets[client.rawValue], bucket.turns > 0 else {
                return nil
            }
            return BreakdownEntry(client: client, bucket: bucket)
        }
    }

    private struct LastWarning {
        let toolName: String
        let formattedTime: String
    }

    private var mostRecentWarning: LastWarning? {
        var pick: (Date, LLMDuplicateWarning)?
        for bucket in todayBuckets.values {
            if let warn = bucket.lastWarning {
                if pick == nil || warn.at > pick!.0 {
                    pick = (warn.at, warn)
                }
            }
        }
        guard let (date, warn) = pick else { return nil }
        return LastWarning(toolName: warn.toolName, formattedTime: Self.timeFormatter.string(from: date))
    }

    private struct TodayTotals {
        let costDisplay: String
        let hasUnpriced: Bool
    }

    private func totalsForToday() -> TodayTotals {
        var cost: Double = 0
        var allUnpriced = true
        var anyUnpriced = false
        var anyPriced = false
        var anyTurns = false
        for bucket in todayBuckets.values where bucket.turns > 0 {
            anyTurns = true
            cost += bucket.costUsd
            if bucket.unpricedTurns > 0 { anyUnpriced = true }
            if bucket.unpricedTurns < bucket.turns { anyPriced = true; allUnpriced = false }
        }
        if !anyTurns {
            return TodayTotals(costDisplay: LLMSpendFormatting.formatCost(0), hasUnpriced: false)
        }
        if allUnpriced && !anyPriced {
            return TodayTotals(costDisplay: "—", hasUnpriced: true)
        }
        let prefix = anyUnpriced ? "~" : ""
        return TodayTotals(costDisplay: prefix + LLMSpendFormatting.formatCost(cost), hasUnpriced: anyUnpriced)
    }

    private var showOnboarding: Bool {
        model.llmStatsSnapshot.days.isEmpty
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func formattedTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    // MARK: - Actions

    private func exportLinesForCurrentPort() -> [String] {
        let port = model.llmProxyPort
        return [
            "export ANTHROPIC_BASE_URL=http://127.0.0.1:\(port)",
            "export OPENAI_BASE_URL=http://127.0.0.1:\(port)",
        ]
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedKey = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedKey == text { copiedKey = nil }
        }
    }

    private func parsedPort() -> UInt16? {
        guard let value = Int(portFieldText.trimmingCharacters(in: .whitespaces)),
              value > 0, value <= 65535 else { return nil }
        return UInt16(value)
    }

    private func applyPort() {
        guard let port = parsedPort(), port != model.llmProxyPort else { return }
        model.setLLMProxyPort(port)
    }

    private func syncFields() {
        portFieldText = String(model.llmProxyPort)
        openAIUpstreamText = model.llmProxyOpenAIUpstream.absoluteString
        anthropicUpstreamText = model.llmProxyAnthropicUpstream.absoluteString
    }

    // MARK: - Compression (RTK)

    private var compressionSection: some View {
        let status = model.hooks.rtkStatus
        let busy = model.hooks.isRtkSetupBusy
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("settings.llmSpend.compression.title"))
                    .font(.headline)
                Text(lang.t("settings.llmSpend.compression.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            compressionStatusRow(status: status, busy: busy)
            if status?.state == .installedEnabled,
               let summary = model.llmStatsSnapshot.compressionSummary,
               summary.totalCommands > 0 {
                compressionStatsRow(summary)
            }
        }
    }

    private func compressionStatusRow(status: RTKInstallationStatus?, busy: Bool) -> some View {
        HStack(spacing: 12) {
            compressionStatusBadge(status: status)
            Spacer()
            compressionButtons(status: status, busy: busy)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func compressionStatusBadge(status: RTKInstallationStatus?) -> some View {
        let (label, color): (String, Color)
        switch status?.state {
        case .none, .notInstalled:
            (label, color) = (lang.t("settings.llmSpend.compression.statusNotInstalled"), .secondary)
        case .installedDisabled:
            (label, color) = (lang.t("settings.llmSpend.compression.statusInstalledDisabled"), .orange)
        case .installedEnabled:
            (label, color) = (lang.t("settings.llmSpend.compression.statusEnabled"), .green)
        case .needsRepair:
            (label, color) = (lang.t("settings.llmSpend.compression.statusNeedsRepair"), .orange)
        case .unsupportedArchitecture:
            (label, color) = (lang.t("settings.llmSpend.compression.intelMacUnsupported"), .secondary)
        }
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func compressionButtons(status: RTKInstallationStatus?, busy: Bool) -> some View {
        let state = status?.state ?? .notInstalled
        switch state {
        case .unsupportedArchitecture:
            // Intel: there's nothing the user can do. Don't render
            // ghost buttons that look interactive.
            EmptyView()
        case .notInstalled:
            Button(busy
                   ? lang.t("settings.llmSpend.compression.installingButton")
                   : lang.t("settings.llmSpend.compression.installButton")) {
                showRTKConfirmSheet = true
            }
            .disabled(busy)
        case .installedDisabled, .needsRepair:
            HStack(spacing: 8) {
                Button(state == .needsRepair
                       ? lang.t("settings.llmSpend.compression.repairButton")
                       : lang.t("settings.llmSpend.compression.installButton")) {
                    showRTKConfirmSheet = true
                }
                .disabled(busy)
                Button(busy
                       ? lang.t("settings.llmSpend.compression.uninstallingButton")
                       : lang.t("settings.llmSpend.compression.uninstallButton"),
                       role: .destructive) {
                    model.hooks.uninstallRtk()
                }
                .disabled(busy)
            }
        case .installedEnabled:
            Button(busy
                   ? lang.t("settings.llmSpend.compression.uninstallingButton")
                   : lang.t("settings.llmSpend.compression.uninstallButton"),
                   role: .destructive) {
                model.hooks.uninstallRtk()
            }
            .disabled(busy)
        }
    }

    private func compressionStatsRow(_ summary: CompressionSummary) -> some View {
        // RTK gain reports cumulative summary — never per-day or
        // per-client. Surface it as "all time" rather than fake a
        // 7-day window we don't have data for. The ⓘ tooltip
        // clarifies the savings-percent metric: same RTK source as
        // `rtk gain` (per-command equal-weight average since the
        // first run), so adjacent snapshots can drift a few percent
        // when new long-output commands land — the user shouldn't
        // read that drift as a different methodology.
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .foregroundStyle(.secondary)
            Text(String(
                format: lang.t("settings.llmSpend.compression.statsAllTime"),
                "\(summary.totalCommands)",
                String(format: "%.1f", summary.avgSavingsPct)
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(compressionStatsTooltip(for: summary))
        }
    }

    private func compressionStatsTooltip(for summary: CompressionSummary) -> String {
        // Same date format as the rest of the pane's bookkeeping
        // (yyyy-MM-dd HH:mm in local time). Localized formatter
        // would re-order Western/CJK ordering, but RTK gain itself
        // emits ISO-style timestamps, so matching that keeps the
        // tooltip's timestamp recognizable when the user cross-
        // references rtk gain --history in a terminal.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let lastSync = formatter.string(from: summary.lastUpdatedAt)
        return String(
            format: lang.t("settings.llmSpend.compression.statsTooltip"),
            lastSync
        )
    }

    private var rtkConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.t("settings.llmSpend.compression.confirmSheetTitle"))
                .font(.title3.weight(.semibold))
            Text(String(
                format: lang.t("settings.llmSpend.compression.confirmSheetBody"),
                RTKInstallationManager.RTK_VERSION
            ))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(lang.t("settings.llmSpend.compression.confirmSheetCancel")) {
                    showRTKConfirmSheet = false
                }
                Button(lang.t("settings.llmSpend.compression.confirmSheetConfirm")) {
                    showRTKConfirmSheet = false
                    Task { await model.hooks.installRtk() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Agents (per-agent quota / plan info)

    /// Loads each `AgentUsageProvider` sequentially. Order is
    /// deterministic — the panel always renders Claude → Codex →
    /// Cursor in that order regardless of which providers actually
    /// returned data. Copilot is intentionally NOT listed: a probe
    /// of local data sources (CLI not installed at the spec'd
    /// paths, VS Code globalStorage carries only an SKU string with
    /// no quota, GitHub `copilot/*` REST endpoints all 404 as of
    /// 2026-05) found no usable data. Provider deferred to Phase 3
    /// if/when GitHub publishes an official quota API or the VS
    /// Code extension data proves stable across updates. The
    /// `.copilot` `LLMClient` enum case added in Phase 2.1 is
    /// retained as a forward-compatibility placeholder.
    @MainActor
    private func loadAgentUsages() async {
        let providers: [any AgentUsageProvider] = [
            ClaudeAgentUsageProvider(),
            CodexAgentUsageProvider(),
            CursorUsageProvider(),
        ]
        var collected: [AgentUsageSnapshot] = []
        for provider in providers {
            if let snap = await provider.load(), !snap.isEmpty {
                collected.append(snap)
            }
        }
        self.agentSnapshots = collected
    }

    /// Read the cached DeepSeek balance, optionally triggering a
    /// network refresh when the cache is stale (>15 min) or empty.
    /// Failures (missing credential, HTTP error) are swallowed —
    /// the card detail line just stays absent until the user
    /// configures a key + the next pane appearance retries.
    @MainActor
    private func loadDeepseekBalance() async {
        let provider = model.llmProxy.deepseekBalance
        let cached = await provider.cachedSnapshot()
        let stale = await provider.isStale()
        if let cached, !stale {
            self.deepseekBalanceSnapshot = cached
            return
        }
        do {
            self.deepseekBalanceSnapshot = try await provider.refresh()
        } catch {
            // Keep whatever we had — a stale snapshot is better
            // than nothing, and no snapshot is better than a
            // misleading "$0.00".
            self.deepseekBalanceSnapshot = cached
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        if !agentSnapshots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.t("settings.llmSpend.agents.title"))
                        .font(.headline)
                    Text(lang.t("settings.llmSpend.agents.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    ForEach(agentSnapshots, id: \.client) { snap in
                        agentCard(snap)
                    }
                }
            }
        }
    }

    private func agentCard(_ snap: AgentUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Self.color(for: snap.client))
                    .frame(width: 8, height: 8)
                Text(snap.client.displayName)
                    .font(.subheadline.weight(.semibold))
                if let plan = snap.planLabel, !plan.isEmpty {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if snap.source.isUnofficial {
                    HStack(spacing: 3) {
                        Image(systemName: "info.circle")
                        Text(lang.t("settings.llmSpend.agents.unofficialBadge"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(lang.t("settings.llmSpend.agents.unofficialTooltip"))
                }
                Spacer()
            }
            if snap.windows.isEmpty {
                Text(lang.t("settings.llmSpend.agents.quotaUnavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snap.windows, id: \.label) { w in
                    agentUsageWindowRow(w)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func agentUsageWindowRow(_ w: AgentUsageWindow) -> some View {
        HStack(spacing: 10) {
            Text(w.label)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            ProgressView(value: min(1.0, max(0.0, w.usedPercentage / 100)))
                .progressViewStyle(.linear)
                .tint(Self.color(forUsedPercentage: w.usedPercentage))
            Text("\(w.roundedUsedPercentage)%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// Per-client dot color. Mirrors `LLMSpendStatsView.color(for:)`
    /// — kept duplicated rather than extracted to a shared helper
    /// because the two views are tab/sheet siblings, not a
    /// component family yet.
    private static func color(for client: LLMClient) -> Color {
        switch client {
        case .claudeCode: return .orange
        case .codex:      return .blue
        case .cursor:     return .purple
        case .copilot:    return .green
        case .unknown:    return .secondary
        }
    }

    /// Same 60/85% thresholds the context-fill bar uses on the
    /// island pill. Centralized so the two visual languages don't
    /// drift apart.
    private static func color(forUsedPercentage pct: Double) -> Color {
        if pct >= LLMSpendStatsView.contextFillCriticalThreshold * 100 { return .red }
        if pct >= LLMSpendStatsView.contextFillWarnThreshold * 100 { return .orange }
        return .blue
    }
}

// MARK: - Shared formatting

enum LLMSpendFormatting {
    static func formatCost(_ value: Double) -> String {
        if value < 0.01, value > 0 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }
}
