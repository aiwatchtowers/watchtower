import SwiftUI
import WatchtowerCore

/// What the tab hands to other surfaces: a run step's links.
struct AutomationsTabActions {
    /// A step's proposal → the Inbox.
    var onOpenInbox: ((Int64) -> Void)?
    /// A workbench run's step session → that session on its workbench page.
    var onOpenSession: ((_ projectID: Int64, _ sessionID: Int64) -> Void)?
    /// A workbench run's step ask → that ask's drawer on its workbench page.
    var onOpenAsk: ((_ projectID: Int64, _ askID: Int64) -> Void)?
    /// A built-in's on/off and When fields (the feature keys and config).
    var builtin = BuiltinCardActions()
}

/// What the panel needs from `AppState`: the scopes a new automation can
/// have, the editor chats (built on `embeddedChatCenter`) and the template
/// panels (`AutomationTemplatePanels`, so an install outlives the panel).
struct AutomationEditorChatHooks {
    /// Personal first, then one per workbench (its folder as the full path).
    let scopes: [AutomationScopeChoice]
    /// The workspace directory: a personal draft's recipe goes to its
    /// `automations` folder.
    let workspaceDir: String
    /// A fresh new draft's conversation key for a scope.
    let draftContextID: (AutomationScopeChoice) -> String
    let makeNewChat: (_ contextID: String, _ scope: AutomationScopeChoice) async throws -> AutomationEditorChat?
    let makeEditChat: (Int64) async throws -> AutomationEditorChat?
    /// The open panel of a template in a scope (made on first use).
    let templatePanel: (_ name: String, _ scope: AutomationScopeChoice) -> AutomationTemplatePanelModel?
    /// **Continue** on a template: its panel, a fresh one when the last
    /// install of it in that scope finished.
    let startTemplate: (_ name: String, _ scope: AutomationScopeChoice) -> AutomationTemplatePanelModel?
}

/// The Automations tab (spec A1): a list of sections — Personal, then one
/// per workbench, drafts first —
/// with the detail panel on the right. Every flow (a card, New, a template,
/// the editor) happens in that panel; none is a sheet. State lives in the
/// `AppState`-owned `AutomationsViewModel`, `AutomationEditorCenter` and
/// template panels; only the search text is local.
struct AutomationsView: View {
    @Bindable var vm: AutomationsViewModel
    var actions = AutomationsTabActions()
    var emptyStateContext: EmptyStateContext = .neutral
    var editor: AutomationEditorCenter?
    let hooks: AutomationEditorChatHooks
    /// The Feature Manager's disabled ids.
    var disabledFeatures: Set<String> = []
    /// The feature manager is applying a change: a built-in's Turn On/Off waits.
    var isApplyingFeatures = false

    @State private var searchText = ""

    /// **Watch for something**: the editor chat starts on a watch recipe.
    static let watchPrefill = "Watch for "

    private var workbenches: [(id: Int64, name: String)] {
        hooks.scopes.compactMap {
            if case let .workbench(id, name, _) = $0 { return (id, name) }
            return nil
        }
    }

    private var sections: [AutomationListSection] {
        AutomationListSections.make(items: vm.items, drafts: vm.draftRows, workbenches: workbenches, query: searchText)
    }

    /// No automation and no draft at all.
    private var isEmpty: Bool { vm.items.isEmpty && vm.draftRows.isEmpty }

    var body: some View {
        PanelSplit(
            isPanelShown: true,
            width: PanelSplitWidth(key: "automations.detailWidth", range: 720...1600, ideal: 900)
        ) {
            listColumn
        } panel: {
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .detailBackground()
        .navigationTitle("Automations")
        .onAppear {
            vm.setTabVisible(true)
            autoSelect()
        }
        .onDisappear { vm.setTabVisible(false) }
        .onChange(of: vm.items.map(\.id)) { _, _ in autoSelect() }
        .onChange(of: vm.pendingConfirmID, initial: true) { _, _ in
            vm.consumePendingConfirm()
        }
    }

    /// The first listed automation, while the panel shows nothing else; an
    /// automation whose row is not listed (its workbench not loaded yet) is
    /// never picked.
    private func autoSelect() {
        vm.autoSelect(first: sections.lazy.flatMap(\.items).first?.id)
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.regular) {
                Text("Automations")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    vm.showNew(AutomationNewFlow())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.kitIcon(isOn: false))
                .help("New automation")
                .accessibilityLabel("New automation")
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.top, Spacing.medium)

            HStack(spacing: Spacing.compact) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SearchField(text: $searchText, placeholder: "Search automations")
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.regular)

            if let message = vm.lastError {
                WriteErrorBanner(message: message) { vm.lastError = nil }
                    .padding(.bottom, Spacing.regular)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    let now = Date()
                    ForEach(sections) { section in
                        SectionHeader(title: section.title, systemImage: Self.sectionIcon(section.id),
                                      count: section.count)
                            .padding(.horizontal, Spacing.regular)
                            .padding(.top, Spacing.medium)
                            .padding(.bottom, Spacing.small)
                        // Draft rows are keyed by their context id: a
                        // conversation id may equal an automation's id.
                        ForEach(section.drafts, id: \.contextID) { row in
                            AutomationDraftListRow(row: row, isSelected: isOpen(row), now: now) { open(row) }
                        }
                        ForEach(section.items) { item in
                            AutomationListRow(
                                item: item,
                                changes: vm.details[item.id]?.changes,
                                isSelected: vm.selectedID == item.id,
                                now: now
                            ) { vm.select(item.id) }
                        }
                    }
                }
                .padding(.horizontal, Spacing.regular)
                .padding(.bottom, Spacing.medium)
            }
            .overlay {
                if sections.isEmpty, !isEmpty, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No automation matches “\(searchText)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func sectionIcon(_ id: String) -> String {
        switch id {
        case "builtin": "shippingbox"
        case "personal": "person"
        default: "folder"
        }
    }

    private func isOpen(_ row: AutomationDraftRow) -> Bool {
        if case let .editor(.newDraft(contextID, _, _)) = vm.panel { return contextID == row.contextID }
        return false
    }

    /// A draft row opens the editor on its chat, in the scope it was started in.
    /// A workbench draft whose workbench is not listed opens nothing: it
    /// never opens as a personal chat (ask #469).
    private func open(_ row: AutomationDraftRow) {
        let scope: AutomationScopeChoice
        if let id = row.workbenchID {
            guard let workbench = hooks.scopes.first(where: { $0.workbenchID == id }) else { return }
            scope = workbench
        } else {
            scope = .personal
        }
        vm.showEditor(.newDraft(contextID: row.contextID, scope: scope, startText: nil))
    }

    // MARK: - Panel

    @ViewBuilder private var panel: some View {
        switch vm.panel {
        case .empty:
            emptyPanel
        case let .card(id):
            if let item = vm.items.first(where: { $0.id == id }), item.automation.isBuiltin {
                builtinCard(item)
            } else if let item = vm.items.first(where: { $0.id == id }) {
                AutomationCardView(
                    vm: vm,
                    item: item,
                    actions: actions,
                    workbenchName: item.automation.projectID.flatMap(workbenchName),
                    now: Date()
                ) { vm.showEditor(.existing(id)) }
                .id(id)
            } else {
                emptyPanel
            }
        case let .new(flow):
            AutomationNewPanel(flow: flow, scopes: hooks.scopes, templates: vm.templates,
                               templatesLoading: vm.templatesLoading) { scope, start in
                continueNew(flow, scope: scope, start: start)
            }
            .task { await vm.loadTemplates() }
        case let .template(name, scope):
            if let model = hooks.templatePanel(name, scope) {
                AutomationTemplatePanel(
                    model: model,
                    onAdjustInChat: { text in
                        vm.showEditor(.newDraft(contextID: hooks.draftContextID(scope), scope: scope, startText: text))
                    },
                    onDone: { id in vm.templateFinished(name: name, scope: scope, firstID: id) }
                )
                .id(AutomationTemplatePanels.key(template: name, scope: scope))
            } else {
                placeholder("This template is not available any more.")
            }
        case let .editor(target):
            if let editor {
                AutomationEditorPanel(
                    target: target,
                    editor: editor,
                    vm: vm,
                    makeChat: { try await makeChat(target) },
                    scopeTitle: scopeTitle(target),
                    workspaceDir: hooks.workspaceDir,
                    composerPrefill: vm.composerPrefill,
                    turnOnBuiltin: turnOnBuiltin(target),
                    onSaved: { vm.showCard($0) },
                    onDiscardDraft: discardHandler(target)
                )
                .id(target)
            } else {
                placeholder("The editor is not available yet.")
            }
        }
    }

    /// A built-in's card, kept by the view model; it reads the newest row.
    private func builtinCard(_ item: AutomationListItem) -> some View {
        let automation = item.automation
        let card = vm.builtinCard(automation)
        return BuiltinAutomationCard(
            model: card,
            isApplyingFeatures: isApplyingFeatures,
            actions: actions.builtin,
            onEdit: { vm.showEditor(.existing(automation.id)) },
            onChanged: { vm.refresh(drafts: false) }
        )
        .onChange(of: item, initial: true) { _, row in card.observe(row) }
        .id(automation.id)
    }

    /// **Save and Turn On** under a built-in's draft: its feature ids on,
    /// through the same path as the card's Turn On; nil for any other draft.
    private func turnOnBuiltin(_ target: AutomationEditorTarget) -> (() async -> Void)? {
        guard case let .existing(id, _) = target,
              let automation = vm.items.first(where: { $0.id == id })?.automation, automation.isBuiltin
        else { return nil }
        let card = vm.builtinCard(automation)
        let setEnabled = actions.builtin.setEnabled
        return { await card.setEnabled(true, setEnabled) }
    }

    @ViewBuilder private var emptyPanel: some View {
        if isEmpty {
            TabEmptyState(.automations, context: emptyStateContext, onTabAction: {
                vm.showNew(AutomationNewFlow())
            }, extra: { EmptyView() })
        } else {
            placeholder("Select an automation")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **Continue** in the New panel: the editor chat on a fresh draft (the
    /// composer prefill carried), or the template's panel — started afresh
    /// when its last install in that scope finished.
    private func continueNew(_ flow: AutomationNewFlow, scope: AutomationScopeChoice, start: AutomationStart) {
        switch start {
        case .words:
            vm.showEditor(.newDraft(contextID: hooks.draftContextID(scope), scope: scope, startText: nil),
                          composerPrefill: flow.composerPrefill)
        case .watch:
            vm.showEditor(.newDraft(contextID: hooks.draftContextID(scope), scope: scope, startText: nil),
                          composerPrefill: Self.watchPrefill)
        case let .template(name):
            guard hooks.startTemplate(name, scope) != nil else { return }
            vm.showTemplate(name: name, scope: scope)
        }
    }

    private func makeChat(_ target: AutomationEditorTarget) async throws -> AutomationEditorChat? {
        switch target {
        case let .existing(id, _): try await hooks.makeEditChat(id)
        case let .newDraft(contextID, scope, _): try await hooks.makeNewChat(contextID, scope)
        }
    }

    private func discardHandler(_ target: AutomationEditorTarget) -> (() -> Void)? {
        guard case let .newDraft(contextID, _, _) = target else { return nil }
        return { vm.discardDraft(contextID: contextID) }
    }

    private func workbenchName(_ id: Int64) -> String? {
        workbenches.first { $0.id == id }?.name
    }

    private func scopeTitle(_ target: AutomationEditorTarget) -> String {
        switch target {
        case let .existing(id, _):
            guard let automation = vm.items.first(where: { $0.id == id })?.automation else {
                return AutomationListSections.personalTitle
            }
            if automation.isBuiltin { return AutomationListSections.builtinTitle }
            guard automation.scope == .workbench else { return AutomationListSections.personalTitle }
            return automation.projectID.flatMap(workbenchName) ?? "Workbench"
        case let .newDraft(_, scope, _):
            if case let .workbench(_, name, _) = scope { return name }
            return AutomationListSections.personalTitle
        }
    }
}
