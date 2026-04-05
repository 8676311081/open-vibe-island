import SwiftUI
import OpenIslandCore

// MARK: - Settings tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case display
    case sound
    case shortcuts
    case lab
    case about

    var id: String { rawValue }

    func label(_ lang: LanguageManager) -> String {
        switch self {
        case .general:   lang.t("settings.tab.general")
        case .display:   lang.t("settings.tab.display")
        case .sound:     lang.t("settings.tab.sound")
        case .shortcuts: lang.t("settings.tab.shortcuts")
        case .lab:       lang.t("settings.tab.lab")
        case .about:     lang.t("settings.tab.about")
        }
    }

    var icon: String {
        switch self {
        case .general:   "gearshape.fill"
        case .display:   "textformat.size"
        case .sound:     "speaker.wave.2.fill"
        case .shortcuts: "keyboard.fill"
        case .lab:       "flask.fill"
        case .about:     "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general:   .gray
        case .display:   .blue
        case .sound:     .green
        case .shortcuts: .gray
        case .lab:       .pink
        case .about:     .blue
        }
    }

    var section: SettingsSection {
        switch self {
        case .general, .display, .sound: .system
        case .shortcuts, .lab:           .advanced
        case .about:                     .app
        }
    }
}

enum SettingsSection: String, CaseIterable {
    case system
    case advanced
    case app

    func header(_ lang: LanguageManager) -> String {
        switch self {
        case .system:   lang.t("settings.section.system")
        case .advanced: lang.t("settings.section.advanced")
        case .app:      "Open Island"
        }
    }

    var tabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0.section == self }
    }
}

// MARK: - Root settings view

struct SettingsView: View {
    var model: AppModel
    @State private var selectedTab: SettingsTab = .general

    private var lang: LanguageManager { model.lang }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView
        }
        .frame(minWidth: 680, minHeight: 480)
        .frame(width: 780, height: 560)
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                Section(section.header(lang)) {
                    ForEach(section.tabs) { tab in
                        Label {
                            Text(tab.label(lang))
                        } icon: {
                            Image(systemName: tab.icon)
                                .foregroundStyle(tab.iconColor)
                        }
                        .tag(tab)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsPane(model: model)
        case .display:
            DisplaySettingsPane(model: model)
        case .sound:
            SoundSettingsPane(model: model)
        case .shortcuts:
            PlaceholderSettingsPane(model: model, titleKey: "settings.tab.shortcuts", subtitleKey: "settings.shortcuts.comingSoon")
        case .lab:
            PlaceholderSettingsPane(model: model, titleKey: "settings.tab.lab", subtitleKey: "settings.lab.comingSoon")
        case .about:
            AboutSettingsPane(model: model)
        }
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    var model: AppModel

    @State private var launchAtLogin = false
    @State private var confirmingUninstallClaude = false
    @State private var confirmingUninstallCodex = false

    private var lang: LanguageManager { model.lang }

    var body: some View {
        Form {
            Section(lang.t("settings.section.system")) {
                Toggle(lang.t("settings.general.launchAtLogin"), isOn: $launchAtLogin)

                Picker(lang.t("settings.general.monitor"), selection: Binding(
                    get: { model.overlayDisplaySelectionID },
                    set: { model.overlayDisplaySelectionID = $0 }
                )) {
                    Text(lang.t("settings.general.automatic")).tag(OverlayDisplayOption.automaticID)
                    ForEach(model.overlayDisplayOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            }

            Section(lang.t("settings.general.language")) {
                Picker(lang.t("settings.general.language"), selection: Binding(
                    get: { lang.language },
                    set: { lang.language = $0 }
                )) {
                    Text(lang.t("settings.general.languageSystem")).tag(LanguageManager.AppLanguage.system)
                    Text(lang.t("settings.general.languageEnglish")).tag(LanguageManager.AppLanguage.en)
                    Text(lang.t("settings.general.languageChinese")).tag(LanguageManager.AppLanguage.zhHans)
                }
            }

            Section(lang.t("settings.general.behavior")) {
                Toggle(lang.t("settings.general.hideFullscreen"), isOn: .constant(false))
                Toggle(lang.t("settings.general.autoHideNoSessions"), isOn: .constant(false))
                Toggle(lang.t("settings.general.autoCollapse"), isOn: .constant(true))
            }

            Section(lang.t("settings.general.cliHooks")) {
                HStack {
                    Text("Claude Code")
                    Spacer()
                    if model.claudeHooksInstalled {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(lang.t("settings.general.activated"))
                                    .foregroundStyle(.secondary)
                            }
                            Button(lang.t("settings.general.uninstall")) {
                                confirmingUninstallClaude = true
                            }
                            .foregroundStyle(.red)
                            .font(.caption)
                        }
                    } else {
                        Button(lang.t("settings.general.install")) {
                            model.installClaudeHooks()
                        }
                        .disabled(model.hooksBinaryURL == nil)
                    }
                }
                .alert(lang.t("settings.general.uninstallConfirmTitle"), isPresented: $confirmingUninstallClaude) {
                    Button(lang.t("settings.general.uninstallConfirmAction"), role: .destructive) {
                        model.uninstallClaudeHooks()
                    }
                    Button(lang.t("settings.general.cancel"), role: .cancel) {}
                } message: {
                    Text(lang.t("settings.general.uninstallConfirmMessage.claude"))
                }

                HStack {
                    Text("Codex")
                    Spacer()
                    if model.codexHooksInstalled {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(lang.t("settings.general.activated"))
                                    .foregroundStyle(.secondary)
                            }
                            Button(lang.t("settings.general.uninstall")) {
                                confirmingUninstallCodex = true
                            }
                            .foregroundStyle(.red)
                            .font(.caption)
                        }
                    } else {
                        Button(lang.t("settings.general.install")) {
                            model.installCodexHooks()
                        }
                        .disabled(model.hooksBinaryURL == nil)
                    }
                }
                .alert(lang.t("settings.general.uninstallConfirmTitle"), isPresented: $confirmingUninstallCodex) {
                    Button(lang.t("settings.general.uninstallConfirmAction"), role: .destructive) {
                        model.uninstallCodexHooks()
                    }
                    Button(lang.t("settings.general.cancel"), role: .cancel) {}
                } message: {
                    Text(lang.t("settings.general.uninstallConfirmMessage.codex"))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.general"))
    }
}

// MARK: - Display

struct DisplaySettingsPane: View {
    var model: AppModel

    private var lang: LanguageManager { model.lang }

    var body: some View {
        Form {
            Section(lang.t("settings.display.monitor")) {
                Picker(lang.t("settings.display.position"), selection: Binding(
                    get: { model.overlayDisplaySelectionID },
                    set: { model.overlayDisplaySelectionID = $0 }
                )) {
                    Text(lang.t("settings.general.automatic")).tag(OverlayDisplayOption.automaticID)
                    ForEach(model.overlayDisplayOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            }

            if let diag = model.overlayPlacementDiagnostics {
                Section(lang.t("settings.display.diagnostics")) {
                    LabeledContent(lang.t("settings.display.currentScreen"), value: diag.targetScreenName)
                    LabeledContent(lang.t("settings.display.layoutMode"), value: diag.modeDescription)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.display"))
    }
}

// MARK: - Sound

struct SoundSettingsPane: View {
    var model: AppModel

    private var lang: LanguageManager { model.lang }

    private var availableSounds: [String] {
        NotificationSoundService.availableSounds()
    }

    var body: some View {
        Form {
            Section(lang.t("settings.sound.notifications")) {
                Toggle(lang.t("settings.sound.mute"), isOn: Binding(
                    get: { model.isSoundMuted },
                    set: { _ in model.toggleSoundMuted() }
                ))
            }

            Section(lang.t("settings.sound.selectSound")) {
                List(availableSounds, id: \.self) { name in
                    Button {
                        model.selectedSoundName = name
                        NotificationSoundService.play(name)
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if name == model.selectedSoundName {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(lang.t("settings.tab.sound"))
    }
}

// MARK: - About

struct AboutSettingsPane: View {
    var model: AppModel

    private var lang: LanguageManager { model.lang }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "island")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(lang.t("app.name"))
                .font(.title.bold())
            Text(lang.t("app.description"))
                .foregroundStyle(.secondary)
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text(lang.t("settings.about.version", version))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(lang.t("settings.tab.about"))
    }
}

// MARK: - Placeholder

struct PlaceholderSettingsPane: View {
    var model: AppModel
    let titleKey: String
    let subtitleKey: String

    private var lang: LanguageManager { model.lang }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(lang.t(subtitleKey))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(lang.t(titleKey))
    }
}
