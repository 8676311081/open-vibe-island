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
                if let warning = mostRecentWarning {
                    duplicateWarningSection(warning)
                }
                controlsSection
                upstreamsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(lang.t("settings.tab.llmSpend"))
        .onAppear { syncFields() }
        .onChange(of: model.llmProxyPort) { _, _ in syncFields() }
        .onChange(of: model.llmProxyOpenAIUpstream) { _, _ in syncFields() }
        .onChange(of: model.llmProxyAnthropicUpstream) { _, _ in syncFields() }
        .sheet(isPresented: $showStatsSheet) {
            LLMSpendStatsView(model: model)
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
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isLLMProxyRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.isLLMProxyRunning
                     ? lang.t("settings.llmSpend.proxyRunning")
                     : lang.t("settings.llmSpend.proxyStopped"))
                    .font(.subheadline.weight(.medium))
            }

            Divider().frame(height: 16)

            Text("\(lang.t("settings.llmSpend.port")): 127.0.0.1:\(model.llmProxyPort)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            todayPill
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var todayPill: some View {
        let totals = totalsForToday()
        return HStack(spacing: 6) {
            Text(lang.t("settings.llmSpend.todayTotal"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(totals.costDisplay)
                .font(.title3.weight(.semibold))
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
}

// MARK: - Shared formatting

enum LLMSpendFormatting {
    static func formatCost(_ value: Double) -> String {
        if value < 0.01, value > 0 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }
}
