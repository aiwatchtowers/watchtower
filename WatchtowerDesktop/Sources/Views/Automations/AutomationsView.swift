import SwiftUI
import WatchtowerCore

/// What the tab hands to other surfaces. A nil hook leaves its button
/// disabled until the surface behind it exists (New automation sheet,
/// Templates gallery, Edit form, Change in words — plan Tasks 10, 11, 13).
struct AutomationsTabActions {
    var onNew: (() -> Void)?
    var onTemplates: (() -> Void)?
    var onEdit: ((Int64) -> Void)?
    var onChangeInWords: ((Int64) -> Void)?
    /// Why **Change in words** is off though the chat exists (R-P3-12: under
    /// ollama the editor chat cannot draft).
    var changeInWordsDisabledHelp: String?
    /// The card's "Needs your confirmation" → the confirmation sheet.
    var onConfirm: ((Int64) -> Void)?
    /// A step's proposal → the Inbox.
    var onOpenInbox: ((Int64) -> Void)?
    /// A workbench run's step session → that session on its workbench page.
    var onOpenSession: ((_ projectID: Int64, _ sessionID: Int64) -> Void)?
    /// A workbench run's step ask → that ask's drawer on its workbench page.
    var onOpenAsk: ((_ projectID: Int64, _ askID: Int64) -> Void)?
}

/// How the tab opens the editor chats ("Change in words", the "New
/// automation" sheet); `AppState` builds them on `embeddedChatCenter`.
struct AutomationEditorChatHooks {
    let open: (Int64) throws -> AutomationEditorChat?
    let openNew: () throws -> AutomationEditorChat?
    /// `<workspace>/automations`, where the New sheet's **Form** tab saves.
    let automationsDir: String?
    /// Non-nil when the provider has no tools (ollama): Change in words is
    /// disabled with this help.
    let unavailableHelp: String?
}

/// The Automations tab (spec §12.1, approved mockup 1): a header with
/// **Templates**, **+ New** and "Search automations", the list on the left
/// and the selected automation's card on the right. All state lives in the
/// `AppState`-owned `AutomationsViewModel`; only the search text is local.
/// With an `editor`, **Edit** opens the edit form and the card's "Needs your
/// confirmation" opens the confirmation sheet; their drafts and saves live in
/// the `AppState`-owned `AutomationEditorCenter`, only which sheet is up is local.
struct AutomationsView: View {
    @Bindable var vm: AutomationsViewModel
    var actions = AutomationsTabActions()
    var workbenchName: (Int64) -> String? = { _ in nil }
    var emptyStateContext: EmptyStateContext = .neutral
    var editor: AutomationEditorCenter?
    var chats: AutomationEditorChatHooks?
    /// Whether the Tracks sidebar tab is visible; the Tracks section follows it.
    var tracksVisible = true

    /// A sheet shown for one automation.
    private struct SheetTarget: Identifiable {
        let id: Int64
    }

    @AppStorage(AutomationsSection.storageKey) private var storedSection = ""
    @State private var searchText = ""
    @State private var editing: SheetTarget?
    @State private var confirming: SheetTarget?
    @State private var changingInWords: SheetTarget?
    /// "Change it in words instead" from the edit form: shown once the form
    /// sheet has finished closing (two sheets in one transaction can drop one).
    @State private var pendingChangeInWords: SheetTarget?
    @State private var creating = false
    @State private var browsingTemplates = false
    /// Which sheet to open once the one closing has finished (two sheets in
    /// one transaction can drop one).
    @State private var pendingSheet: HandOff?

    private enum HandOff { case gallery, newAutomation }

    private var cardActions: AutomationsTabActions {
        var out = actions
        if editor != nil {
            out.onEdit = { editing = SheetTarget(id: $0) }
            out.onConfirm = { confirming = SheetTarget(id: $0) }
        }
        if let chats {
            out.onNew = { creating = true }
            out.onTemplates = { browsingTemplates = true }
            if let help = chats.unavailableHelp {
                out.changeInWordsDisabledHelp = help
            } else {
                out.onChangeInWords = { id in
                    if editing != nil {
                        // From the edit form: its sheet's onDismiss opens the chat.
                        pendingChangeInWords = SheetTarget(id: id)
                        editing = nil
                    } else {
                        changingInWords = SheetTarget(id: id)
                    }
                }
            }
        }
        return out
    }

    private var filteredItems: [AutomationListItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return vm.items }
        return vm.items.filter {
            $0.automation.name.localizedCaseInsensitiveContains(query)
                || $0.automation.slug.localizedCaseInsensitiveContains(query)
        }
    }

    private var section: AutomationsSection {
        AutomationsSection.resolve(stored: storedSection, tracksVisible: tracksVisible)
    }

    /// Today's tab: the recipe list and card, or its empty state. The section
    /// picker sits above it, so Reactions and Tracks stay reachable with no recipes.
    @ViewBuilder private var automationsContent: some View {
            if let message = vm.lastError {
                errorBanner(message)
            }
            if vm.items.isEmpty {
                TabEmptyState(.automations, context: emptyStateContext, onTabAction: { cardActions.onNew?() }, extra: {
                    if cardActions.onTemplates != nil {
                        Button("Browse templates") { cardActions.onTemplates?() }
                            .buttonStyle(.link)
                    }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    listPanel
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
                    cardPanel
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: Binding(
                get: { section },
                set: { storedSection = $0.rawValue }
            )) {
                ForEach(AutomationsSection.visible(tracksVisible: tracksVisible), id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            Divider()
            switch section {
            case .automations:
                automationsContent
            case .reactions:
                ReactionsSectionView(items: vm.items, onOpenAutomation: { id in
                    storedSection = AutomationsSection.automations.rawValue
                    searchText = ""
                    vm.select(id)
                }, onNew: cardActions.onNew)
            case .tracks:
                TracksSectionView()
            }
        }
        .navigationTitle("Automations")
        .onAppear {
            vm.setTabVisible(true)
            selectFirstIfNeeded()
        }
        .onDisappear { vm.setTabVisible(false) }
        .onChange(of: vm.items.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .sheet(item: $editing, onDismiss: openPendingChangeInWords) { target in
            if let editor {
                AutomationFormView(
                    editor: editor,
                    vm: vm,
                    automationID: target.id,
                    onChangeInWords: cardActions.onChangeInWords
                ) { editing = nil }
            }
        }
        .sheet(item: $confirming) { target in
            if let editor {
                AutomationConfirmSheet(vm: vm, editor: editor, automationID: target.id) { confirming = nil }
            }
        }
        .sheet(item: $changingInWords) { target in
            if let chats {
                AutomationChangeInWordsSheet(
                    name: vm.items.first { $0.id == target.id }?.automation.name ?? "automation",
                    make: { try chats.open(target.id) },
                    onClose: { changingInWords = nil }
                )
            }
        }
        .sheet(isPresented: $creating, onDismiss: openPendingSheet) {
            if let chats {
                NewAutomationSheet(vm: vm, editor: editor, makeChat: chats.openNew,
                                   automationsDir: chats.automationsDir,
                                   onTemplates: { pendingSheet = .gallery; creating = false },
                                   onClose: { creating = false })
            }
        }
        .sheet(isPresented: $browsingTemplates, onDismiss: openPendingSheet) {
            AutomationTemplateGalleryView(vm: vm, onDescribeInWords: {
                pendingSheet = .newAutomation
                browsingTemplates = false
            }, onClose: { browsingTemplates = false })
        }
        .onChange(of: vm.pendingEditID, initial: true) { _, _ in openInstalledTemplate() }
        .onChange(of: vm.pendingConfirmID, initial: true) { _, _ in openPendingConfirmation() }
    }

    /// An unconfirmed row picked in the "Run Automation…" palette: the same
    /// confirmation sheet as the card's "Needs your confirmation".
    private func openPendingConfirmation() {
        guard editor != nil, let id = vm.pendingConfirmID else { return }
        vm.pendingConfirmID = nil
        confirming = SheetTarget(id: id)
    }

    private func openPendingSheet() {
        guard let pending = pendingSheet else { return openInstalledTemplate() }
        pendingSheet = nil
        switch pending {
        case .gallery: browsingTemplates = true
        case .newAutomation: creating = true
        }
    }

    /// A template was installed: its edit form opens, unconfirmed (Save confirms).
    private func openInstalledTemplate() {
        guard editor != nil, !browsingTemplates, !creating, let id = vm.pendingEditID else { return }
        vm.pendingEditID = nil
        editing = SheetTarget(id: id)
    }

    /// The edit form's sheet finished closing: open the chat it handed off to.
    private func openPendingChangeInWords() {
        guard let pending = pendingChangeInWords else { return }
        pendingChangeInWords = nil
        changingInWords = pending
    }

    /// The card is never blank while there are automations to show.
    private func selectFirstIfNeeded() {
        guard vm.selectedID == nil || !vm.items.contains(where: { $0.id == vm.selectedID }),
              let first = filteredItems.first ?? vm.items.first else { return }
        vm.select(first.id)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                vm.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - List

    private var listPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Automations")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Templates") { cardActions.onTemplates?() }
                    .disabled(cardActions.onTemplates == nil)
                Button("+ New") { cardActions.onNew?() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cardActions.onNew == nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search automations")
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    let now = Date()
                    ForEach(filteredItems) { item in
                        AutomationListRow(
                            item: item,
                            changes: vm.details[item.id]?.changes,
                            isSelected: vm.selectedID == item.id,
                            now: now
                        ) { vm.select(item.id) }
                        Divider()
                    }
                }
            }
            .overlay {
                if filteredItems.isEmpty {
                    Text("No automation matches “\(searchText)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .panelBackground()
    }

    // MARK: - Card

    @ViewBuilder private var cardPanel: some View {
        if let id = vm.selectedID, let item = vm.items.first(where: { $0.id == id }) {
            AutomationCardView(
                vm: vm,
                item: item,
                actions: cardActions,
                workbenchName: item.automation.projectID.flatMap(workbenchName),
                now: Date()
            )
            .id(id)
        } else {
            Text("Select an automation")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
