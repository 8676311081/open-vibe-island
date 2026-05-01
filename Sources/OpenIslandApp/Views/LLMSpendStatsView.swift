import Charts
import OpenIslandCore
import SwiftUI

/// Detailed spend analytics, presented as a sheet from
/// `LLMSpendSettingsPane`. Reads-only: derives every number from
/// `model.llmStatsSnapshot` (refreshed on a 1.5 s cadence by the app).
///
/// P0 scope: Today/Week/Month/All segmented control, four summary
/// cards (tokens / cost / cache hit / messages), a daily-cost bar
/// chart, and a per-client breakdown table. P1 (chart click → focus
/// day) and P2 (CSV export) are intentionally not implemented yet.
struct LLMSpendStatsView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRange: TimeRange = .month

    private var lang: LanguageManager { model.lang }

    enum TimeRange: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }

        /// Inclusive day count to walk back from today. `nil` = unbounded
        /// (caller falls back to the snapshot's earliest day).
        var dayWindow: Int? {
            switch self {
            case .today: return 1
            case .week:  return 7
            case .month: return 30
            case .all:   return nil
            }
        }

        func label(_ lang: LanguageManager) -> String {
            switch self {
            case .today: return lang.t("settings.llmSpend.stats.range.today")
            case .week:  return lang.t("settings.llmSpend.stats.range.week")
            case .month: return lang.t("settings.llmSpend.stats.range.month")
            case .all:   return lang.t("settings.llmSpend.stats.range.allTime")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    contextFillBanner
                    lowCacheHitBanner
                    rangePicker
                    if rangeData.isEmpty {
                        emptyState
                    } else {
                        summaryCards
                        chartSection
                        bySourceSection
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 600, idealHeight: 680)
    }

    // MARK: - Context fill banner (60% / 85% thresholds)

    /// Thresholds for the banner color/visibility. Shared with
    /// `IslandPanelView`'s pill progress bar so the two surfaces
    /// can't disagree on what "yellow" means.
    static let contextFillWarnThreshold: Double = 0.60
    static let contextFillCriticalThreshold: Double = 0.85

    /// Cache-hit ratio below which we suggest a compression tool.
    /// Rationale (review C alternative-plan): below ~30% the user
    /// is paying full uncached prompt tokens often enough that
    /// pointing them at RTK / similar wrappers is likely to help;
    /// above 30% the gain from compression is dwarfed by the
    /// existing cache wins, so the suggestion would be noise.
    static let LOW_CACHE_HIT_THRESHOLD: Double = 0.30
    /// Number of buckets we require before showing the cache banner —
    /// the ratio over a single day is too noisy to trust.
    static let CACHE_BANNER_MIN_DAYS: Int = 3

    @ViewBuilder
    private var lowCacheHitBanner: some View {
        if let ratio = recentWeekCacheHit(), ratio < Self.LOW_CACHE_HIT_THRESHOLD {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lang.t("settings.llmSpend.stats.lowCacheHitTitle"))
                        .font(.subheadline.weight(.semibold))
                    Text(String(
                        format: lang.t("settings.llmSpend.stats.lowCacheHitBody"),
                        Int((ratio * 100).rounded())
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Weighted cache-hit ratio over the last 7 days:
    ///   sum(cacheRead) / sum(cacheRead + cacheCreation + input)
    /// Returns `nil` when the buckets covering that window have no
    /// breakdown data (legacy snapshot) or fewer than
    /// `CACHE_BANNER_MIN_DAYS` distinct days with traffic — too
    /// little signal to act on. Independent of the
    /// Today/Week/Month/All time-range picker because the banner is
    /// a current-state nudge, not a per-range stat.
    private func recentWeekCacheHit() -> Double? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = Self.dayKeyFormatter
        var buckets: [LLMDayBucket] = []
        var daysWithTraffic = 0
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let key = formatter.string(from: day)
            guard let dayBuckets = model.llmStatsSnapshot.days[key] else { continue }
            var anyTraffic = false
            for bucket in dayBuckets.values where bucket.turns > 0 {
                buckets.append(bucket)
                anyTraffic = true
            }
            if anyTraffic { daysWithTraffic += 1 }
        }
        guard daysWithTraffic >= Self.CACHE_BANNER_MIN_DAYS else { return nil }
        return LLMCacheHitAggregator.ratio(of: buckets)
    }

    @ViewBuilder
    private var contextFillBanner: some View {
        // Render the banner for whichever client is closest to its
        // limit. Skipped when no client has crossed 60% (or no
        // upstream has streamed a usage envelope yet).
        if let (_, ratio) = highestContextFill(), ratio >= Self.contextFillWarnThreshold {
            let isCritical = ratio >= Self.contextFillCriticalThreshold
            let color = isCritical ? Color.red : Color.orange
            let labelKey = isCritical
                ? "settings.llmSpend.stats.contextFillCritical"
                : "settings.llmSpend.stats.contextFillWarning"
            HStack(spacing: 10) {
                Image(systemName: isCritical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lang.t(labelKey))
                        .font(.subheadline.weight(.semibold))
                    Text(String(
                        format: lang.t("settings.llmSpend.stats.contextFillSubtitle"),
                        Int((ratio * 100).rounded())
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Greatest fill ratio seen across all clients. Returns `nil`
    /// when nothing's been recorded yet (fresh app, or active
    /// model isn't in `ModelContextLimits`).
    private func highestContextFill() -> (LLMClient, Double)? {
        var best: (LLMClient, Double)?
        for (client, ratio) in model.llmContextFill {
            if best == nil || ratio > best!.1 {
                best = (client, ratio)
            }
        }
        return best
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(lang.t("common.close"))

            Text(lang.t("settings.llmSpend.stats.title"))
                .font(.title3.weight(.semibold))
                .padding(.leading, 4)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLLMProxyRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.isLLMProxyRunning
                     ? "\(lang.t("settings.llmSpend.proxyOn")) :\(model.llmProxyPort)"
                     : lang.t("settings.llmSpend.proxyStopped"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("", selection: $selectedRange) {
            ForEach(TimeRange.allCases) { range in
                Text(range.label(lang)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Summary cards

    private var summaryCards: some View {
        let totals = aggregateTotals()
        let compression = model.llmStatsSnapshot.compressionSummary
        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            statCard(
                label: lang.t("settings.llmSpend.stats.cardTokens"),
                value: formattedTokens(totals.totalTokens)
            )
            statCard(
                label: lang.t("settings.llmSpend.stats.cardCost"),
                value: totals.costDisplay,
                emphasis: totals.hasUnpriced ? .orange : nil,
                tooltip: totals.hasUnpriced ? lang.t("settings.llmSpend.unpricedTooltip") : nil
            )
            statCard(
                label: lang.t("settings.llmSpend.stats.cardCacheHit"),
                value: totals.cacheHitDisplay,
                emphasis: totals.cacheHitRatio == nil ? .secondary : nil,
                tooltip: totals.cacheHitRatio == nil
                    ? lang.t("settings.llmSpend.stats.cacheHitLegacyTooltip")
                    : nil
            )
            statCard(
                label: lang.t("settings.llmSpend.stats.cardMessages"),
                value: "\(totals.totalTurns)"
            )
            // RTK compression is cross-agent + cross-day so it ignores
            // the time-range picker — the value is always the all-time
            // cumulative `total_saved` from rtk gain. nil → "—" with
            // explanatory tooltip; UI never invents a per-range
            // attribution we don't have.
            // Saved-by-compression is the only card whose value is
            // ambiguous without an explicit unit ("750" alone reads
            // as "tokens? requests? K tokens?"). Tokens / Cost /
            // Cache Hit / Messages each have their unit visible
            // already (M suffix, $ prefix, % suffix, label = "messages
            // count"). Pass `unit: "tokens"` here only.
            statCard(
                label: lang.t("settings.llmSpend.stats.cardSavedByCompression"),
                value: compression.map { formattedTokens($0.totalSavedTokens) } ?? "—",
                unit: compression == nil ? nil : "tokens",
                emphasis: compression == nil ? .secondary : nil,
                tooltip: compression == nil
                    ? lang.t("settings.llmSpend.stats.savedByCompressionUnavailable")
                    : lang.t("settings.llmSpend.stats.savedByCompressionTooltip")
            )
        }
    }

    private func statCard(
        label: String,
        value: String,
        unit: String? = nil,
        emphasis: Color? = nil,
        tooltip: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(emphasis ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .help(tooltip ?? "")
    }

    // MARK: - Chart

    private var chartSection: some View {
        let series = dailyCostSeries()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lang.t("settings.llmSpend.stats.dailyCost").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                if let span = dateSpanLabel() {
                    Text(span)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Chart(series) { point in
                BarMark(
                    x: .value(lang.t("settings.llmSpend.stats.axisDay"), point.date, unit: .day),
                    y: .value(lang.t("settings.llmSpend.stats.cardCost"), point.cost)
                )
                .foregroundStyle(point.isToday ? Color.orange.opacity(0.55) : Color.orange)
                .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(LLMSpendFormatting.formatCost(raw))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: xAxisValues(series)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xAxisLabel(for: date, series: series))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 220)
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
        }
    }

    // MARK: - By Source

    private var bySourceSection: some View {
        let entries = clientBreakdown()
        return VStack(alignment: .leading, spacing: 10) {
            Text(lang.t("settings.llmSpend.stats.bySource").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            VStack(spacing: 0) {
                bySourceHeader
                Divider()
                ForEach(Array(entries.enumerated()), id: \.element.client) { index, entry in
                    bySourceRow(entry)
                    if index < entries.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
        }
    }

    private var bySourceHeader: some View {
        HStack(spacing: 0) {
            Text(lang.t("settings.llmSpend.stats.colClient"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
            Text(lang.t("settings.llmSpend.stats.colTurns"))
                .frame(width: 70, alignment: .trailing)
            Text(lang.t("settings.llmSpend.stats.colTokens"))
                .frame(width: 90, alignment: .trailing)
            Text(lang.t("settings.llmSpend.stats.colCost"))
                .frame(width: 80, alignment: .trailing)
            Text(lang.t("settings.llmSpend.stats.colCacheHit"))
                .frame(width: 80, alignment: .trailing)
            Text(lang.t("settings.llmSpend.stats.colWasted"))
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .tracking(0.3)
        .padding(.vertical, 8)
    }

    private func bySourceRow(_ entry: ClientEntry) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: entry.client))
                    .frame(width: 8, height: 8)
                Text(entry.client.displayName)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)

            Text("\(entry.turns)")
                .font(.subheadline.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Text(formattedTokens(entry.totalTokens))
                .font(.subheadline.monospacedDigit())
                .frame(width: 90, alignment: .trailing)
            Text(entry.costDisplay)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(entry.hasUnpriced ? Color.orange : Color.primary)
                .frame(width: 80, alignment: .trailing)
                .help(entry.hasUnpriced ? lang.t("settings.llmSpend.unpricedTooltip") : "")
            Text(entry.cacheHitDisplay)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(entry.cacheHitRatio == nil ? Color.secondary : Color.primary)
                .help(entry.cacheHitRatio == nil
                      ? lang.t("settings.llmSpend.stats.cacheHitLegacyTooltip")
                      : "")
                .frame(width: 80, alignment: .trailing)
            Text(entry.unusedToolTokensWasted == 0
                 ? "—"
                 : formattedTokens(entry.unusedToolTokensWasted))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(entry.unusedToolTokensWasted == 0
                                 ? Color.secondary
                                 : Color.orange)
                .help(lang.t("settings.llmSpend.stats.wastedTooltip"))
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(lang.t("settings.llmSpend.stats.empty"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Aggregation

    private struct Totals {
        var totalTokens: Int = 0
        var totalCost: Double = 0
        var totalTurns: Int = 0
        /// `nil` when no bucket in range recorded a cache breakdown
        /// (legacy snapshots only) — render as "—" not "0%".
        var cacheHitRatio: Double? = nil
        var anyUnpriced: Bool = false
        var allUnpriced: Bool = true
        var anyTurns: Bool = false

        var hasUnpriced: Bool { anyUnpriced }

        var costDisplay: String {
            if !anyTurns { return LLMSpendFormatting.formatCost(0) }
            if allUnpriced { return "—" }
            let prefix = anyUnpriced ? "~" : ""
            return prefix + LLMSpendFormatting.formatCost(totalCost)
        }

        var cacheHitDisplay: String { LLMSpendStatsView.formatRatio(cacheHitRatio) }
    }

    private struct ClientEntry {
        let client: LLMClient
        var turns: Int
        var totalTokens: Int
        var cost: Double
        var cacheHitRatio: Double?
        var unpricedTurns: Int
        /// Sum of `LLMDayBucket.unusedToolTokensWasted` over the
        /// selected range — tokens this client paid to ship as
        /// schemas the model never invoked.
        var unusedToolTokensWasted: Int

        var hasUnpriced: Bool { unpricedTurns > 0 }

        var costDisplay: String {
            if turns > 0, unpricedTurns == turns { return "—" }
            let prefix = hasUnpriced ? "~" : ""
            return prefix + LLMSpendFormatting.formatCost(cost)
        }

        var cacheHitDisplay: String { LLMSpendStatsView.formatRatio(cacheHitRatio) }
    }

    /// Renders a `Double?` cache-hit ratio. `nil` → "—" (legacy/unknown);
    /// otherwise an integer percentage. Centralized so both the summary
    /// card and per-source rows agree on the legacy-vs-zero distinction.
    /// `nonisolated` because it's called from the inner `Totals` /
    /// `ClientEntry` structs, which aren't main-actor.
    nonisolated static func formatRatio(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private struct DailyCostPoint: Identifiable {
        let id: String  // dayKey
        let date: Date
        let cost: Double
        let isToday: Bool
    }

    /// Buckets within the selected range, indexed by day key.
    /// Computed once per view recomposition; cheap (snapshot is small).
    private var rangeData: [(dayKey: String, date: Date, buckets: [String: LLMDayBucket])] {
        let snapshot = model.llmStatsSnapshot
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = Self.dayKeyFormatter

        // For .all, derive earliest day from snapshot keys; for others walk back.
        if let window = selectedRange.dayWindow {
            return (0..<window).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                    return nil
                }
                let key = formatter.string(from: day)
                let buckets = snapshot.days[key] ?? [:]
                return (key, day, buckets)
            }.reversed()
        } else {
            // All-time: union of every day key in the snapshot, sorted ascending.
            let keys = snapshot.days.keys.sorted()
            return keys.compactMap { key in
                guard let day = formatter.date(from: key) else { return nil }
                return (key, day, snapshot.days[key] ?? [:])
            }
        }
    }

    private func aggregateTotals() -> Totals {
        var t = Totals()
        var bucketsForRatio: [LLMDayBucket] = []
        for entry in rangeData {
            for bucket in entry.buckets.values where bucket.turns > 0 {
                t.anyTurns = true
                t.totalTurns += bucket.turns
                t.totalTokens += bucket.tokensIn + bucket.tokensOut
                t.totalCost += bucket.costUsd
                if bucket.unpricedTurns > 0 { t.anyUnpriced = true }
                if bucket.unpricedTurns < bucket.turns { t.allUnpriced = false }
                bucketsForRatio.append(bucket)
            }
        }
        if !t.anyTurns { t.allUnpriced = false }
        t.cacheHitRatio = LLMCacheHitAggregator.ratio(of: bucketsForRatio)
        return t
    }

    private func clientBreakdown() -> [ClientEntry] {
        let order: [LLMClient] = [.claudeCode, .codex, .cursor, .unknown]
        var bucketsByClient: [LLMClient: [LLMDayBucket]] = [:]
        var aggregateByClient: [LLMClient: (turns: Int, tokens: Int, cost: Double, unpriced: Int, wasted: Int)] = [:]

        for entry in rangeData {
            for (rawClient, bucket) in entry.buckets where bucket.turns > 0 {
                let client = LLMClient(rawValue: rawClient) ?? .unknown
                bucketsByClient[client, default: []].append(bucket)
                var sums = aggregateByClient[client] ?? (0, 0, 0, 0, 0)
                sums.turns += bucket.turns
                sums.tokens += bucket.tokensIn + bucket.tokensOut
                sums.cost += bucket.costUsd
                sums.unpriced += bucket.unpricedTurns
                sums.wasted += bucket.unusedToolTokensWasted
                aggregateByClient[client] = sums
            }
        }
        return order.compactMap { client in
            guard let sums = aggregateByClient[client] else { return nil }
            let ratio = LLMCacheHitAggregator.ratio(of: bucketsByClient[client] ?? [])
            return ClientEntry(
                client: client,
                turns: sums.turns,
                totalTokens: sums.tokens,
                cost: sums.cost,
                cacheHitRatio: ratio,
                unpricedTurns: sums.unpriced,
                unusedToolTokensWasted: sums.wasted
            )
        }
    }

    private func dailyCostSeries() -> [DailyCostPoint] {
        let todayKey = LLMStatsStore.dayKey(for: Date())
        return rangeData.map { entry in
            var cost: Double = 0
            for bucket in entry.buckets.values {
                cost += bucket.costUsd
            }
            return DailyCostPoint(
                id: entry.dayKey, date: entry.date, cost: cost,
                isToday: entry.dayKey == todayKey
            )
        }
    }

    // MARK: - Axis helpers

    /// Pick a sparse set of x-axis tick dates so labels don't overlap.
    private func xAxisValues(_ series: [DailyCostPoint]) -> [Date] {
        guard !series.isEmpty else { return [] }
        // Aim for ~5 labels regardless of range length.
        let target = 5
        let stride = max(1, series.count / target)
        var picked: [Date] = []
        for (i, p) in series.enumerated() where i % stride == 0 {
            picked.append(p.date)
        }
        // Always include the last point so "today" shows up.
        if let last = series.last?.date, picked.last != last {
            picked.append(last)
        }
        return picked
    }

    private func xAxisLabel(for date: Date, series: [DailyCostPoint]) -> String {
        if selectedRange == .today {
            return Self.timeFormatter.string(from: date)
        }
        if let last = series.last?.date,
           Calendar.current.isDate(date, inSameDayAs: last) {
            return lang.t("settings.llmSpend.stats.todayShort")
        }
        return Self.shortDateFormatter.string(from: date)
    }

    private func dateSpanLabel() -> String? {
        guard let first = rangeData.first?.date,
              let last = rangeData.last?.date else { return nil }
        let f = Self.shortDateFormatter
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return f.string(from: first)
        }
        return "\(f.string(from: first)) — \(f.string(from: last))"
    }

    // MARK: - Formatting

    private func formattedTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func color(for client: LLMClient) -> Color {
        switch client {
        case .claudeCode: return .orange
        case .codex:      return .blue
        case .cursor:     return .purple
        case .copilot:    return .green
        case .unknown:    return .secondary
        }
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
