import SwiftUI
import OpenIslandCore

// MARK: - AutoResponseSettingsPane

struct AutoResponseSettingsPane: View {
    var model: AppModel

    @State private var selectedRuleID: UUID?
    @State private var editingRule: AutoResponseRule?

    private var lang: LanguageManager { model.lang }

    var body: some View {
        HSplitView {
            ruleListView
                .frame(minWidth: 200, maxWidth: 260)
            editorView
                .frame(minWidth: 320)
        }
        .navigationTitle(lang.t("settings.tab.autoResponse"))
    }

    // MARK: - Rule List

    private var ruleListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedRuleID) {
                if model.autoResponseRules.isEmpty {
                    Text(lang.t("settings.autoResponse.noRules"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.autoResponseRules) { rule in
                        ruleRow(rule)
                            .tag(rule.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button(action: addRule) {
                    Label(lang.t("settings.autoResponse.newRule"), systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                if selectedRuleID != nil {
                    Button(action: deleteSelectedRule) {
                        Label(lang.t("settings.autoResponse.deleteRule"), systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
    }

    private func ruleRow(_ rule: AutoResponseRule) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    if let idx = model.autoResponseRules.firstIndex(where: { $0.id == rule.id }) {
                        model.autoResponseRules[idx].enabled = newValue
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.body)
                    .lineLimit(1)
                Text(rule.ruleType == .permission
                     ? lang.t("settings.autoResponse.type.permission")
                     : lang.t("settings.autoResponse.type.question"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Editor

    private var editorView: some View {
        Group {
            if let editingRule {
                AutoResponseRuleEditor(
                    rule: editingRule,
                    lang: lang,
                    onSave: { updated in
                        saveRule(updated)
                    }
                )
            } else {
                VStack {
                    Spacer()
                    Text(lang.t("settings.autoResponse.noRules"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .onChange(of: selectedRuleID) { _, newID in
            editingRule = model.autoResponseRules.first(where: { $0.id == newID })
        }
    }

    // MARK: - Actions

    private func addRule() {
        let newRule = AutoResponseRule(
            name: "New Rule",
            ruleType: .permission,
            conditions: RuleConditions(),
            action: .allow
        )
        model.autoResponseRules.append(newRule)
        selectedRuleID = newRule.id
        editingRule = newRule
    }

    private func deleteSelectedRule() {
        guard let id = selectedRuleID else { return }
        model.autoResponseRules.removeAll(where: { $0.id == id })
        selectedRuleID = nil
        editingRule = nil
    }

    private func saveRule(_ rule: AutoResponseRule) {
        if let idx = model.autoResponseRules.firstIndex(where: { $0.id == rule.id }) {
            model.autoResponseRules[idx] = rule
        }
        editingRule = rule
    }
}

// MARK: - AutoResponseRuleEditor

struct AutoResponseRuleEditor: View {
    @State var rule: AutoResponseRule
    let lang: LanguageManager
    let onSave: (AutoResponseRule) -> Void

    @State private var toolNamesText: String = ""
    @State private var keywordsText: String = ""
    @State private var denyMessage: String = ""
    @State private var optionIndex: Int = 0
    @State private var selectKeyword: String = ""

    var body: some View {
        Form {
            Section(lang.t("settings.autoResponse.name")) {
                TextField(lang.t("settings.autoResponse.name"), text: $rule.name)
            }

            Section(lang.t("settings.autoResponse.type")) {
                Picker(lang.t("settings.autoResponse.type"), selection: $rule.ruleType) {
                    Text(lang.t("settings.autoResponse.type.permission")).tag(AutoResponseRuleType.permission)
                    Text(lang.t("settings.autoResponse.type.question")).tag(AutoResponseRuleType.question)
                }
                .pickerStyle(.segmented)
            }

            Section(lang.t("settings.autoResponse.conditions")) {
                TextField(
                    lang.t("settings.autoResponse.toolNames"),
                    text: $toolNamesText,
                    prompt: Text(lang.t("settings.autoResponse.toolNames.placeholder"))
                )

                TextField(
                    lang.t("settings.autoResponse.pathPattern"),
                    text: Binding(
                        get: { rule.conditions.pathPattern ?? "" },
                        set: { rule.conditions.pathPattern = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(lang.t("settings.autoResponse.pathPattern.placeholder"))
                )

                VStack(alignment: .leading) {
                    Text(lang.t("settings.autoResponse.agentTypes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach([AgentTool.claudeCode, .codex, .openCode, .qoder, .factory, .codebuddy], id: \.self) { tool in
                            Toggle(tool.displayName, isOn: Binding(
                                get: { rule.conditions.agentTypes?.contains(tool) ?? false },
                                set: { isOn in
                                    var types = rule.conditions.agentTypes ?? []
                                    if isOn {
                                        if !types.contains(tool) { types.append(tool) }
                                    } else {
                                        types.removeAll(where: { $0 == tool })
                                    }
                                    rule.conditions.agentTypes = types.isEmpty ? nil : types
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                if rule.ruleType == .question {
                    TextField(
                        lang.t("settings.autoResponse.keywords"),
                        text: $keywordsText,
                        prompt: Text(lang.t("settings.autoResponse.keywords.placeholder"))
                    )
                }
            }

            Section(lang.t("settings.autoResponse.action")) {
                if rule.ruleType == .permission {
                    Picker(lang.t("settings.autoResponse.action"), selection: Binding(
                        get: { actionTag },
                        set: { updateAction($0) }
                    )) {
                        Text(lang.t("settings.autoResponse.action.allow")).tag("allow")
                        Text(lang.t("settings.autoResponse.action.deny")).tag("deny")
                    }
                    .pickerStyle(.segmented)

                    if case .deny = rule.action {
                        TextField(lang.t("settings.autoResponse.action.denyMessage"), text: $denyMessage)
                    }
                } else {
                    Picker(lang.t("settings.autoResponse.action"), selection: Binding(
                        get: { actionTag },
                        set: { updateAction($0) }
                    )) {
                        Text(lang.t("settings.autoResponse.action.allow")).tag("allow")
                        Text(lang.t("settings.autoResponse.action.deny")).tag("deny")
                        Text(lang.t("settings.autoResponse.action.selectOption")).tag("selectOption")
                        Text(lang.t("settings.autoResponse.action.selectByKeyword")).tag("selectByKeyword")
                    }

                    switch rule.action {
                    case .deny:
                        TextField(lang.t("settings.autoResponse.action.denyMessage"), text: $denyMessage)
                    case .selectOption:
                        Stepper(
                            "\(lang.t("settings.autoResponse.action.optionIndex")): \(optionIndex)",
                            value: $optionIndex,
                            in: 0...20
                        )
                    case .selectByKeyword:
                        TextField(lang.t("settings.autoResponse.action.keyword"), text: $selectKeyword)
                    default:
                        EmptyView()
                    }
                }

                Text(lang.t("settings.autoResponse.conflict"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(lang.t("settings.autoResponse.save")) {
                    syncToRule()
                    onSave(rule)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .onAppear { syncFromRule() }
        .onChange(of: rule.id) { _, _ in syncFromRule() }
    }

    // MARK: - Sync helpers

    private var actionTag: String {
        switch rule.action {
        case .allow: "allow"
        case .deny: "deny"
        case .selectOption: "selectOption"
        case .selectByKeyword: "selectByKeyword"
        }
    }

    private func updateAction(_ tag: String) {
        switch tag {
        case "allow": rule.action = .allow
        case "deny": rule.action = .deny(message: denyMessage.isEmpty ? nil : denyMessage)
        case "selectOption": rule.action = .selectOption(index: optionIndex)
        case "selectByKeyword": rule.action = .selectByKeyword(selectKeyword)
        default: break
        }
    }

    private func syncFromRule() {
        toolNamesText = rule.conditions.toolNames?.joined(separator: ", ") ?? ""
        keywordsText = rule.conditions.titleKeywords?.joined(separator: ", ") ?? ""
        switch rule.action {
        case .deny(let msg): denyMessage = msg ?? ""
        case .selectOption(let idx): optionIndex = idx
        case .selectByKeyword(let kw): selectKeyword = kw
        default: break
        }
    }

    private func syncToRule() {
        let tools = toolNamesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        rule.conditions.toolNames = tools.isEmpty ? nil : tools

        let kws = keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        rule.conditions.titleKeywords = kws.isEmpty ? nil : kws

        switch rule.action {
        case .deny: rule.action = .deny(message: denyMessage.isEmpty ? nil : denyMessage)
        case .selectOption: rule.action = .selectOption(index: optionIndex)
        case .selectByKeyword: rule.action = .selectByKeyword(selectKeyword)
        default: break
        }
    }
}
