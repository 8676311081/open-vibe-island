import SwiftUI
import OpenIslandCore

// MARK: - Pure state derivation (extracted for unit testability)
//
// SwiftUI views themselves are tedious to instantiate from tests.
// The state-machine logic for "what does this card look like" and
// "should we show a discount-expiring chip" lives here as plain
// functions so the suite in `ModelRoutingPaneTests` can hit them
// directly without a `MainActor` test-environment dance.

/// What rendering state a single profile card is in. Exhaustive —
/// covers the four combinations of `(isActive, hasRequiredCredential)`.
public enum ProfileCardState: Equatable {
    /// Active profile that has the credential it needs (or doesn't
    /// need one — Anthropic Native passes through). Highlighted +
    /// "active" badge.
    case activeAndConfigured
    /// Switchable: user can click to swap to this profile.
    case inactiveAndConfigured
    /// Click opens the key config sheet rather than switching.
    case inactiveAndMissingKey
    /// Defensive: shouldn't happen because `setActiveProfile` should
    /// reject this combination. If it does occur (corrupt
    /// UserDefaults, manual key deletion), pane shows an error
    /// banner — better than silently routing to a broken upstream.
    case errorActiveButMissingKey
}

/// Discount-window state for a profile's pricing metadata. Drives
/// the "X days left" chip on DeepSeek cards while the 75%-off
/// promo is active.
public enum DiscountState: Equatable {
    case noDiscount
    case active(daysRemaining: Int)
    case expired
}

public enum ModelRoutingDerivation {
    /// Show the discount chip during the last `discountCountdownThresholdDays`
    /// days of the window. Earlier than that, the discount is "fresh"
    /// and doesn't need to nudge the user.
    public static let discountCountdownThresholdDays = 30

    public static func cardState(
        profile: UpstreamProfile,
        activeProfileId: String,
        hasCredentialFor: (String) -> Bool
    ) -> ProfileCardState {
        let isActive = profile.id == activeProfileId
        let credPresent: Bool = {
            guard let account = profile.keychainAccount else { return true }
            return hasCredentialFor(account)
        }()
        switch (isActive, credPresent) {
        case (true, true): return .activeAndConfigured
        case (false, true): return .inactiveAndConfigured
        case (false, false): return .inactiveAndMissingKey
        case (true, false): return .errorActiveButMissingKey
        }
    }

    public static func discountState(
        metadata: ProfileCostMetadata?,
        now: Date
    ) -> DiscountState {
        guard let metadata, let expiresAt = metadata.discountExpiresAt else {
            return .noDiscount
        }
        if expiresAt <= now {
            return .expired
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let days = calendar.dateComponents([.day], from: now, to: expiresAt).day ?? 0
        return .active(daysRemaining: max(0, days))
    }

    /// True if `discountState` should drive a UI countdown chip.
    /// Combines "is the discount still active" with "is it close
    /// enough to expiry to be worth surfacing".
    public static func shouldShowCountdown(_ state: DiscountState) -> Bool {
        switch state {
        case .active(let days):
            return days <= discountCountdownThresholdDays
        case .noDiscount, .expired:
            return false
        }
    }

    /// Effective input price to display on a card. After the
    /// discount window expires, fall back to the pre-discount
    /// list price (so the card stays accurate even if no new
    /// release has shipped to bump `inputUSDPerMtok`). 0 list
    /// price means "no list price was filed" — keep current.
    public static func effectiveInputPrice(
        metadata: ProfileCostMetadata,
        now: Date
    ) -> Double {
        if discountState(metadata: metadata, now: now) == .expired,
           metadata.listInputUSDPerMtok > 0 {
            return metadata.listInputUSDPerMtok
        }
        return metadata.inputUSDPerMtok
    }

    public static func effectiveOutputPrice(
        metadata: ProfileCostMetadata,
        now: Date
    ) -> Double {
        if discountState(metadata: metadata, now: now) == .expired,
           metadata.listOutputUSDPerMtok > 0 {
            return metadata.listOutputUSDPerMtok
        }
        return metadata.outputUSDPerMtok
    }
}

// MARK: - Pane

@MainActor
struct ModelRoutingPane: View {
    var model: AppModel

    /// `RouterCredentialsStore` is intentionally non-observable
    /// (avoid Keychain reads on every view tick), so its presence
    /// is mirrored on appear / after-save into local state. Active
    /// profile id flows through `model.activeUpstreamProfileId`
    /// directly — that one IS observable so the chip on the island
    /// pill re-renders simultaneously with this pane on switch.
    @State private var hasDeepseekKey: Bool = false
    @State private var pendingSwitch: UpstreamProfile?
    @State private var configuringProfile: UpstreamProfile?
    @State private var errorBanner: String?
    /// Snapshot of the health monitor refreshed on appear and after
    /// each switch. Live updating (proxy degrading WHILE the pane
    /// is open) is deferred to a future polling-task commit — the
    /// common case is "user opens pane to debug after noticing
    /// errors" which appears on entry.
    @State private var upstreamDegraded: Bool = false
    @State private var upstreamSampleCount: Int = 0

    private var lang: LanguageManager { model.lang }
    private var profileStore: UpstreamProfileStore { model.llmProxy.profileStore }
    private var credentialsStore: RouterCredentialsStore { model.llmProxy.credentialsStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let banner = errorBanner {
                    errorBannerView(banner)
                }
                if upstreamDegraded {
                    healthDegradedBanner
                }
                activeStatusRow
                builtinGrid
                customSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { refreshState() }
        .sheet(item: $pendingSwitch) { profile in
            SwitchConfirmSheet(
                model: model,
                target: profile,
                onConfirm: {
                    pendingSwitch = nil
                    switchActive(to: profile)
                },
                onCancel: { pendingSwitch = nil }
            )
        }
        .sheet(item: $configuringProfile) { profile in
            KeyConfigSheet(
                model: model,
                profile: profile,
                onSaved: {
                    configuringProfile = nil
                    refreshState()
                },
                onCancel: { configuringProfile = nil }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lang.t("modelRouting.title"))
                .font(.title2.weight(.semibold))
            Text(lang.t("modelRouting.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorBannerView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var activeStatusRow: some View {
        let active = model.activeUpstreamProfile
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(lang.t("modelRouting.activeStatus"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(lang.t(active.displayName))
                    .font(.caption.weight(.semibold))
            }
            Text(active.baseURL.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if active.keychainAccount == nil {
                Text(lang.t("modelRouting.activeStatus.passthrough"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(lang.t("modelRouting.activeStatus.rewrite"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var builtinGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(BuiltinProfiles.all) { profile in
                ProfileCard(
                    profile: profile,
                    state: derivedCardState(for: profile),
                    discountState: ModelRoutingDerivation.discountState(
                        metadata: profile.costMetadata,
                        now: .now
                    ),
                    lang: lang,
                    onTap: { handleTap(on: profile) }
                )
            }
            CustomPlaceholderCard(lang: lang, onTap: {
                errorBanner = lang.t("modelRouting.custom.comingSoon")
            })
        }
    }

    private var customSection: some View {
        // Existing custom profiles list — currently always empty
        // because the add flow ships in a follow-up commit. Stub the
        // section out so the layout doesn't shift when entries
        // appear later.
        let custom = profileStore.allProfiles.filter(\.isCustom)
        if custom.isEmpty {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text(lang.t("modelRouting.customSectionTitle"))
                    .font(.headline)
                ForEach(custom) { profile in
                    Text(lang.t(profile.displayName))
                        .font(.body)
                }
            }
            .padding(.top, 8)
        )
    }

    private func derivedCardState(for profile: UpstreamProfile) -> ProfileCardState {
        ModelRoutingDerivation.cardState(
            profile: profile,
            activeProfileId: model.activeUpstreamProfileId,
            hasCredentialFor: { credentialsStore.hasCredential(for: $0) }
        )
    }

    private func handleTap(on profile: UpstreamProfile) {
        let state = derivedCardState(for: profile)
        switch state {
        case .activeAndConfigured, .errorActiveButMissingKey:
            return // already active (or in error state — banner handles)
        case .inactiveAndConfigured:
            pendingSwitch = profile
        case .inactiveAndMissingKey:
            configuringProfile = profile
        }
    }

    private func switchActive(to profile: UpstreamProfile) {
        do {
            // Goes through AppModel so the chip on the compact pill
            // re-renders in lockstep — model.activeUpstreamProfileId
            // is the @Observable mirror.
            try model.setActiveUpstreamProfile(profile.id)
            errorBanner = nil
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// Banner shown when the proxy's recent forwards to the active
    /// upstream are predominantly failing. Renders a "switch back
    /// to Anthropic Native" one-click remediation — the safe
    /// default — alongside the diagnosis text.
    private var healthDegradedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t("modelRouting.health.degraded.title"))
                    .font(.callout.weight(.semibold))
                Text(String(
                    format: lang.t("modelRouting.health.degraded.body"),
                    upstreamSampleCount
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(lang.t("modelRouting.health.degraded.switchBack")) {
                switchActive(to: BuiltinProfiles.anthropicNative)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func refreshState() {
        hasDeepseekKey = credentialsStore.hasCredential(for: "deepseek")
        // Health snapshot. Active profile = Anthropic Native means
        // the user's own credentials are in play; a degraded signal
        // there points at network / Anthropic-side issues, not at
        // our routing layer — still surface, just with the same
        // banner so the user can investigate.
        let monitor = model.llmProxy.healthMonitor
        upstreamDegraded = monitor.isDegraded()
        upstreamSampleCount = monitor.sampleCount()
        // Defensive: surface an error banner if we observe
        // .errorActiveButMissingKey on any built-in.
        for profile in BuiltinProfiles.all {
            if derivedCardState(for: profile) == .errorActiveButMissingKey {
                errorBanner = lang.t("modelRouting.error.activeKeyMissing")
                return
            }
        }
        errorBanner = nil
    }
}

// MARK: - Built-in card

@MainActor
private struct ProfileCard: View {
    let profile: UpstreamProfile
    let state: ProfileCardState
    let discountState: DiscountState
    let lang: LanguageManager
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                topRow
                if let metadata = profile.costMetadata {
                    metadataRows(metadata, profileId: profile.id)
                }
                Spacer(minLength: 0)
                actionRow
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .background(backgroundFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderStroke, lineWidth: state == .activeAndConfigured ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(state == .inactiveAndMissingKey ? 0.65 : 1.0)
    }

    private var topRow: some View {
        HStack(spacing: 6) {
            Text(lang.t(profile.displayName))
                .font(.headline)
            Spacer()
            if state == .activeAndConfigured {
                Text(lang.t("modelRouting.card.activeBadge"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
            }
            if ModelRoutingDerivation.shouldShowCountdown(discountState) {
                if case let .active(days) = discountState {
                    Text(String(format: lang.t("modelRouting.discount.daysRemaining"), days))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func metadataRows(_ metadata: ProfileCostMetadata, profileId: String) -> some View {
        let now = Date()
        let inputPrice = ModelRoutingDerivation.effectiveInputPrice(metadata: metadata, now: now)
        let outputPrice = ModelRoutingDerivation.effectiveOutputPrice(metadata: metadata, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(format: lang.t("modelRouting.card.cost"), inputPrice, outputPrice))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // Anthropic 原生 routes claude-opus-4-7 / sonnet-4-* at
            // 200K AND their `-1m` / `[1m]` extended-context variants
            // at 1M against the same baseURL — the upstream picks
            // window per model id. Showing only "200000 tokens" hid
            // the 1M option; users on Claude CLI's `claude-opus-4-7
            // [1m]` would think they had 200K when ModelContextLimits
            // (post-fix) correctly reports 1M. Special-case the card
            // to surface both.
            anthropicContextLineOrFallback(metadata: metadata, profileId: profileId)
            if metadata.cacheReadUSDPerMtok != nil {
                Text(lang.t("modelRouting.card.cacheSupported"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func anthropicContextLineOrFallback(
        metadata: ProfileCostMetadata, profileId: String
    ) -> some View {
        if profileId == "anthropic-native" {
            Text(lang.t("modelRouting.card.context.anthropicDual"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text(String(format: lang.t("modelRouting.card.context"), metadata.contextWindowTokens))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        switch state {
        case .activeAndConfigured:
            return AnyView(EmptyView())
        case .inactiveAndConfigured:
            return AnyView(
                Text(lang.t("modelRouting.card.action.activate"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            )
        case .inactiveAndMissingKey:
            return AnyView(
                Text(lang.t("modelRouting.card.action.configure"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            )
        case .errorActiveButMissingKey:
            return AnyView(
                Text(lang.t("modelRouting.card.action.error"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            )
        }
    }

    private var backgroundFill: Color {
        switch state {
        case .activeAndConfigured:
            return Color.indigo.opacity(0.15)
        case .inactiveAndConfigured:
            return Color.secondary.opacity(0.06)
        case .inactiveAndMissingKey:
            return Color.secondary.opacity(0.10)
        case .errorActiveButMissingKey:
            return Color.red.opacity(0.10)
        }
    }

    private var borderStroke: Color {
        state == .activeAndConfigured ? .indigo : .secondary.opacity(0.25)
    }
}

// MARK: - Custom placeholder card

@MainActor
private struct CustomPlaceholderCard: View {
    let lang: LanguageManager
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(lang.t("modelRouting.card.custom.title"))
                    .font(.headline)
                Text(lang.t("modelRouting.card.custom.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(lang.t("modelRouting.card.custom.add"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Switch confirm sheet

@MainActor
private struct SwitchConfirmSheet: View {
    var model: AppModel
    let target: UpstreamProfile
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var lang: LanguageManager { model.lang }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: lang.t("modelRouting.confirmSheet.title"), lang.t(target.displayName)))
                .font(.headline)
            Text(lang.t("modelRouting.confirmSheet.bodyCacheLost"))
                .font(.callout)
            Text(lang.t("modelRouting.confirmSheet.bodyPricing"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(lang.t("modelRouting.confirmSheet.bodyHistorySafe"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(lang.t("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(lang.t("modelRouting.confirmSheet.continue"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

// MARK: - Key configuration sheet

@MainActor
private struct KeyConfigSheet: View {
    var model: AppModel
    let profile: UpstreamProfile
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var keyText: String = ""
    @State private var testResult: DeepSeekKeyValidator.Result?
    @State private var isTesting: Bool = false

    private var lang: LanguageManager { model.lang }

    /// Save-button gate: empty key always blocks; otherwise the
    /// connection-tester result decides. `.invalidKey` blocks
    /// (force re-entry); `.rateLimited` / `.upstreamError` /
    /// `.timeout` allow save (key looks fine, upstream is just
    /// transiently unhappy); `.networkError` blocks (we never
    /// reached upstream so we don't know if the key works). Also
    /// blocks if the key string is too short to be a real key —
    /// 20 chars is below any real provider's minimum.
    private var canSave: Bool {
        guard keyText.count >= 20 else { return false }
        return DeepSeekKeyValidator.saveAllowed(for: testResult)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: lang.t("modelRouting.keySheet.title"), lang.t(profile.displayName)))
                .font(.headline)
            Text(lang.t("modelRouting.keySheet.body"))
                .font(.callout)
            if let signupURL = signupURL {
                Link(lang.t("modelRouting.keySheet.signupLink"), destination: signupURL)
                    .font(.callout)
            }
            SecureField(lang.t("modelRouting.keySheet.placeholder"), text: $keyText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: keyText) { _, _ in
                    // Re-test required after edits.
                    testResult = nil
                }
            if let testResult {
                resultRow(testResult)
            }
            HStack {
                Spacer()
                Button(lang.t("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: { Task { await runTest() } }) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(lang.t("modelRouting.keySheet.testConnection"))
                    }
                }
                .disabled(keyText.isEmpty || isTesting)
                Button(lang.t("modelRouting.keySheet.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    private var signupURL: URL? {
        guard let account = profile.keychainAccount else { return nil }
        switch account {
        case "deepseek": return URL(string: "https://platform.deepseek.com")
        default: return nil
        }
    }

    private func resultRow(_ result: DeepSeekKeyValidator.Result) -> some View {
        let (text, color): (String, Color) = {
            switch result {
            case .valid:
                return (lang.t("modelRouting.keySheet.testSuccess"), .green)
            case .invalidKey:
                // Hard error — Save stays disabled. Red.
                return (lang.t("modelRouting.keySheet.testInvalidKey"), .red)
            case .rateLimited:
                // Key works, upstream just rate-limited right now.
                // Save IS allowed; surface as amber notice.
                return (lang.t("modelRouting.keySheet.testRateLimited"), .orange)
            case let .upstreamError(code, body):
                // 4xx (non-401) or 5xx. Save allowed; user can
                // retry once upstream recovers.
                return (
                    String(format: lang.t("modelRouting.keySheet.testFailedStatus"), code, body),
                    .orange
                )
            case .timeout:
                return (lang.t("modelRouting.keySheet.testTimeout"), .orange)
            case let .networkError(message):
                // No HTTP response at all — block save until we
                // confirm the key actually reaches upstream.
                return (
                    String(format: lang.t("modelRouting.keySheet.testFailedNetwork"), message),
                    .red
                )
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: result == .valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
            Spacer()
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        let validator = DeepSeekKeyValidator()
        testResult = await validator.validate(key: keyText)
    }

    private func save() {
        guard let account = profile.keychainAccount else { return }
        do {
            try model.llmProxy.credentialsStore.setCredential(keyText, for: account)
            onSaved()
        } catch {
            // If Keychain refuses, surface as test result so the user
            // sees something rather than the sheet freezing.
            testResult = .networkError(message: error.localizedDescription)
        }
    }
}
