import SwiftUI
import OpenIslandCore

/// Settings → Setup pane section for the realtime web-usage feature.
///
/// Lets the user opt into pulling Max-plan 5h/7d utilization directly
/// from claude.ai's web API. The cookie is stored in macOS Keychain
/// (kSecClassInternetPassword), org_id is auto-resolved on first
/// successful poll, and failure modes (auth expired, schema drift,
/// transport errors) silently fall back to the statusline-fed cache.
///
/// See docs/usage-freshness-investigation.md for the rationale and
/// the full investigation that led to this feature.
struct ClaudeWebUsageSection: View {
    @Bindable var model: AppModel
    @State private var cookieDraft: String = ""
    @State private var savedJustNow: Bool = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pull realtime account-level 5h/7d usage from claude.ai instead of waiting for Claude Code's statusline. Your session cookie is stored only in macOS Keychain and is sent only to claude.ai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(
                    get: { model.claudeWebUsageEnabled },
                    set: { model.claudeWebUsageEnabled = $0 }
                )) {
                    Text("Enable realtime web usage (experimental)")
                }
                .toggleStyle(.switch)
            }

            if model.claudeWebUsageEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Session cookie")
                            .frame(width: 110, alignment: .leading)
                        SecureField("sessionKey=…", text: $cookieDraft)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Claude session cookie")
                        Button(model.claudeWebUsageHasCookie ? "Replace" : "Save") {
                            model.setClaudeWebUsageCookie(cookieDraft)
                            cookieDraft = ""
                            savedJustNow = true
                        }
                        .disabled(cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.claudeWebUsageHasCookie {
                            Button("Clear", role: .destructive) {
                                model.setClaudeWebUsageCookie("")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        Text("Organization")
                            .frame(width: 110, alignment: .leading)
                        TextField("auto-resolved", text: Binding(
                            get: { model.claudeWebUsageOrgID },
                            set: { model.claudeWebUsageOrgID = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .help("Open Island fetches your default organization on first poll. Override only if you need a specific UUID.")
                    }

                    HStack(spacing: 8) {
                        statusBadge
                        Spacer()
                        Button("Refresh now") {
                            model.refreshClaudeWebUsageNow()
                        }
                        .controlSize(.small)
                        .disabled(!model.claudeWebUsageHasCookie)
                    }

                    if let lastError = model.claudeWebUsagePollerState.lastErrorMessage,
                       model.claudeWebUsagePollerState.consecutiveFailures > 0 {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Get the cookie: open https://claude.ai/settings/usage in Chrome → DevTools → Application → Cookies → claude.ai → copy `sessionKey` value, then paste here as `sessionKey=<value>`. The cookie usually expires every few days; you'll see a red dot when it does.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        } header: {
            HStack(spacing: 4) {
                Text("Realtime Web Usage")
                Text("(experimental)")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let state = model.claudeWebUsagePollerState
        if !model.claudeWebUsageHasCookie {
            badge(color: .gray, text: "No cookie")
        } else if state.consecutiveFailures >= ClaudeWebUsagePoller.driftFailureThreshold {
            badge(color: .orange, text: "Drift suspected — \(state.consecutiveFailures) failures")
        } else if state.consecutiveFailures > 0,
                  let msg = state.lastErrorMessage,
                  msg.contains("expired") || msg.contains("rejected") {
            badge(color: .red, text: "Session expired — reconnect")
        } else if let last = state.lastSuccessAt {
            badge(color: .green, text: "Active · last refresh \(relativeTime(last))")
        } else {
            badge(color: .yellow, text: "Awaiting first refresh")
        }
    }

    private func badge(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
