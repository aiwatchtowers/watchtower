import SwiftUI
import WatchtowerCore

/// The right panel's editor (spec A4): **Chat | Form | Script** on the left,
/// all editing one draft in the `AppState`-owned `AutomationEditorCenter`;
/// the draft column on the right shows every hashed field of the bytes on
/// screen as `validate` measured them, and the footer under it saves or
/// confirms exactly those bytes (AUTO-06). No sheet: the column is the
/// confirmation.
struct AutomationEditorPanel: View {
    let target: AutomationEditorTarget
    @Bindable var editor: AutomationEditorCenter
    @Bindable var vm: AutomationsViewModel
    let makeChat: () async throws -> AutomationEditorChat?
    let scopeTitle: String
    /// The workspace directory: a personal draft's recipe goes to its
    /// `automations` folder.
    let workspaceDir: String
    /// The New flow's composer text, put into an empty chat once.
    var composerPrefill: String?
    /// The provider has tools (not Ollama): the Chat segment is on.
    var toolsAvailable = AutomationEditorChatSurface.toolsAvailable(provider: nil)
    let onSaved: (Int64) -> Void
    /// **Discard Draft** of a new draft; nil hides the ⋯ menu.
    let onDiscardDraft: (() -> Void)?

    @State private var chosenMode: AutomationEditorMode?
    @State private var chat: AutomationEditorChat?
    @State private var chatFailure: String?
    @State private var newKey: Int64?
    /// Waits for the owner's press to land, then opens the saved automation;
    /// cancelled when the panel goes, so it never navigates from elsewhere.
    @State private var pressTask: Task<Void, Never>?

    private var mode: AutomationEditorMode { chosenMode ?? .initial(toolsAvailable: hasTools) }
    private var hasTools: Bool { chat?.toolsAvailable ?? toolsAvailable }

    /// The draft's key in the center: the automation's id, or the new
    /// draft's (known once its chat is open).
    private var key: Int64? {
        switch target {
        case let .existing(id, _): id
        case .newDraft: newKey
        }
    }

    private var isNew: Bool {
        if case .newDraft = target { return true }
        return false
    }

    private var form: AutomationFormModel? { key.flatMap { editor.drafts[$0]?.form } }

    /// A save or confirm runs: nothing is editable, so nothing typed is dropped.
    private var isSaving: Bool {
        guard let key else { return false }
        return editor.saving[key] == .saving || editor.confirmations[key] == .confirming
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Spacing.page)
                .padding(.vertical, Spacing.medium)
            HStack(spacing: 0) {
                left
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                Rectangle()
                    .fill(Stroke.hairlineColor)
                    .frame(width: Stroke.hairline)
                draftSide
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 440, maxHeight: .infinity)
            }
        }
        .task { await open() }
        .onDisappear {
            pressTask?.cancel()
            pressTask = nil
            chat?.close()
            chat = nil
        }
        .onChange(of: chat?.draft) { _, draft in
            guard let key, let text = draft?.shownRecipeText else { return }
            editor.adoptChatDraft(key, text: text, slug: draft?.entry?.result?.manifest.slug)
        }
        // Monaco's typing changes the text without a new revision: watch the text.
        .onChange(of: form?.buffer.text) { _, _ in
            if let key { editor.textChanged(key) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Chip(text: scopeTitle, color: Color.accentColor)
            Spacer(minLength: Spacing.regular)
            KitSegmentedPicker(
                title: "Edit with",
                selection: Binding(get: { mode }, set: { chosenMode = $0 }),
                segments: AutomationEditorMode.allCases.map { mode in
                    let off = mode == .chat && !hasTools
                    return KitSegment(value: mode, title: mode.title, isEnabled: !off,
                                      help: off ? AutomationEditorChatSurface.unavailableHelp : nil)
                }
            )
            if isNew, let onDiscardDraft {
                Menu {
                    Button("Discard Draft", role: .destructive) {
                        if let key { editor.discard(key) }
                        onDiscardDraft()
                    }
                    .disabled(isSaving)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.kitIcon(isOn: false))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Draft actions")
            }
        }
    }

    private var title: String {
        if case let .existing(id, _) = target {
            return vm.items.first { $0.id == id }?.automation.name ?? form?.detail.name ?? "Automation"
        }
        if let name = key.flatMap({ editor.lastChecked[$0]?.name }), !name.isEmpty { return name }
        if let draft = chat?.draft, draft.shownRecipeText != nil, !draft.name.isEmpty { return draft.name }
        return "New automation"
    }

    // MARK: - Left: Chat | Form | Script

    @ViewBuilder private var left: some View {
        switch mode {
        case .chat:
            chatPane
        case .form:
            if let form {
                AutomationFormFields(form: form, editor: editor, vm: vm, locked: isSaving) { chosenMode = .script }
                    // A reload replaces the form: start its view state afresh.
                    .id(ObjectIdentifier(form))
            } else {
                draftPlaceholder
            }
        case .script:
            if let form {
                scriptPane(form)
            } else {
                draftPlaceholder
            }
        }
    }

    @ViewBuilder private var chatPane: some View {
        if let chat {
            EmbeddedChatView(
                engine: chat.engine,
                placeholder: "Change something — e.g. 'also at 14:00', 'only from my team'",
                dictationTargetID: "chat.automationEditor.\(chat.conversationID)",
                autoFocus: true,
                accessory: { item in proposals(chat, for: item) },
                footer: { chatFooter(chat) }
            )
        } else if let chatFailure {
            centered {
                Label(chatFailure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.warning)
            }
        } else {
            centered { ProgressView().controlSize(.small) }
        }
    }

    private func scriptPane(_ form: AutomationFormModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if let error = form.buffer.pageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
            }
            // Read-only while a save runs: an edit typed then would be dropped.
            RecipeEditorView(buffer: form.buffer, readOnly: isSaving, slug: form.detail.slug)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .padding(Spacing.medium)
    }

    @ViewBuilder private var draftPlaceholder: some View {
        if let key, case let .failed(message) = editor.saving[key] {
            // The save landed but a later step did not: the draft is gone.
            centered {
                Label(message, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
            }
        } else if let message = key.flatMap({ editor.loadErrors[$0] }) {
            centered {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.warning)
                    .textSelection(.enabled)
            }
        } else if let chatFailure, isNew {
            centered {
                Label(chatFailure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.warning)
            }
        } else {
            centered { ProgressView().controlSize(.small) }
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A turn's `save_automation` cards under its reply (older chats still
    /// have them).
    @ViewBuilder
    private func proposals(_ chat: AutomationEditorChat, for item: ChatThreadItem) -> some View {
        if item.message.isAssistant, !item.message.turnID.isEmpty {
            ForEach(chat.actionFeed.cards(forTurn: item.message.turnID)) { card(chat, $0) }
        }
    }

    /// Proposals of a turn that never stored a reply, and the feed's error.
    @ViewBuilder
    private func chatFooter(_ chat: AutomationEditorChat) -> some View {
        let orphans = AgentActionFeed.unattached(
            rows: chat.actionFeed.rows,
            messageTurnIDs: Set(chat.engine.messages.map(\.message.turnID).filter { !$0.isEmpty })
        )
        if !orphans.isEmpty || chat.actionFeed.lastError != nil || chat.sendNote != nil {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(orphans) { card(chat, $0) }
                if let error = chat.actionFeed.lastError {
                    Text(error).font(.caption).foregroundStyle(Tone.error)
                }
                if let note = chat.sendNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.compact)
        }
    }

    private func card(_ chat: AutomationEditorChat, _ action: AgentAction) -> some View {
        AgentActionCardView(
            action: action,
            inFlight: chat.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chat.actionFeed.approve(action.id, shownArgs: action.argsJSON) } },
            onReject: { Task { await chat.actionFeed.reject(action.id) } },
            onRetry: { Task { await chat.actionFeed.retry(action.id) } },
            gestureError: chat.actionFeed.rowErrors[action.id],
            latestDraftText: chat.draft.shownRecipeText,
            draftSessions: chat.draft.dryRunSessions
        )
    }

    // MARK: - Right: the draft column and its footer

    @ViewBuilder private var draftSide: some View {
        if let key, let form {
            let column = columnModel(form, key: key)
            VStack(spacing: 0) {
                AutomationDraftColumn(model: column, keepAuto: keepAutoBinding(key), onDryRunAgain: dryRunAgain)
                footer(form, key: key, column: column)
            }
        } else if let key, case let .failed(message) = editor.saving[key] {
            // The save landed but its last step did not ("not turned on",
            // "auto could not be kept"): the draft is gone.
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Label(message, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Spacing.regular) {
                    if editor.turnOnPending.contains(key) {
                        Button("Turn On") { retryTurnOn(key) }
                            .buttonStyle(.kitSecondary)
                    }
                    if let savedID = editor.savedIDs[key] {
                        Button("Open Automation") { finish(key, savedID) }
                            .buttonStyle(.kitSecondary)
                    }
                }
            }
            .font(.callout)
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            centered { ProgressView().controlSize(.small) }
        }
    }

    private func columnModel(_ form: AutomationFormModel, key: Int64) -> AutomationDraftColumnModel {
        let state = editor.saving[key]
        var plan: AutomationSavePlan?
        if case let .review(checked) = state { plan = checked }
        // An edit is compared with its saved text; a recipe never confirmed
        // has nothing to compare with.
        let confirmed = isNew || form.detail.confirmedHash.isEmpty ? nil : form.detail.recipeText
        let text = form.renderedText()
        // What `show` says of the saved recipe holds only for its own bytes.
        let detail = form.detail
        let saved = isNew || text != detail.recipeText ? nil : AutomationDraftColumnModel.Saved(
            changedBy: detail.changedBy, changedAt: detail.changedAt,
            needsConfirmation: detail.needsConfirmation, llmAutoWrites: detail.llmAutoWrites
        )
        return AutomationDraftColumnModel(
            text: text,
            validated: editor.lastChecked[key],
            // Checking until the check of these exact bytes returns (a result
            // of other bytes counts as checking in the model too).
            isChecking: state == nil || state == .validating,
            newestChatEntry: chat?.draft.entry,
            confirmedText: confirmed,
            isNew: isNew,
            plan: plan,
            checkFailed: isFailed(key),
            saved: saved
        )
    }

    private var dryRunAgain: (() -> Void)? {
        guard let chat, chat.toolsAvailable, !chat.engine.isBusy else { return nil }
        return { chat.dryRunAgain() }
    }

    private func footer(_ form: AutomationFormModel, key: Int64, column: AutomationDraftColumnModel) -> some View {
        let enabled = vm.items.first { $0.id == key }?.automation.enabled ?? form.detail.enabled
        let verdict = AutomationDraftFooter.make(
            isNew: isNew, bytesChanged: form.buffer.isDirty, enabled: enabled,
            needsConfirmation: form.detail.needsConfirmation, showsAllFields: column.showsAllFields,
            hasErrors: !column.errors.isEmpty
        )
        let ready = editor.canSave(key) && !isSaving
        let checking = column.status == .checking && !isFailed(key)
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            footerMessages(form, key: key, column: column)
            if !checking {
                Text(verdict.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.regular) {
                if isSaving { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                if let secondary = verdict.secondary {
                    Button(secondary.title) { press(secondary, key: key) }
                        .buttonStyle(.kitSecondary)
                        .disabled(!ready)
                }
                Button(checking ? AutomationDraftColumnModel.checkingLine : verdict.primary.title) {
                    press(verdict.primary, key: key)
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || !verdict.primaryEnabled)
            }
        }
        .controlSize(.small)
        .padding(Spacing.large)
    }

    /// The aside line with **Restore**, and why the last save, check or
    /// confirm did not land, with a way on (**Check Again**, **Reload**).
    @ViewBuilder
    private func footerMessages(_ form: AutomationFormModel, key: Int64, column: AutomationDraftColumnModel)
        -> some View {
        if editor.keptAside[key] != nil {
            HStack(spacing: Spacing.regular) {
                Text(editor.asideReason[key] == .reloadedFromDisk
                    ? "Reloaded from disk. Your previous text is kept aside."
                    : AutomationEditorCenter.asideAssistantReplaced)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restore") { editor.restoreAside(key) }
                    .buttonStyle(.kitQuiet)
                    .disabled(isSaving)
            }
        }
        // The column lists a recipe's own errors; any other failure is said here.
        if case let .failed(message) = editor.saving[key], column.errors.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Spacing.regular) {
                    if message == AutomationEditorCenter.changedOnDisk, !isNew {
                        Button("Reload") { Task { await editor.reloadFromDisk(key) } }
                            .buttonStyle(.kitQuiet)
                    }
                    Button("Check Again") { Task { await editor.check(key) } }
                        .buttonStyle(.kitQuiet)
                }
            }
        }
        switch editor.confirmations[key] {
        case let .stale(message), let .failed(message):
            HStack(spacing: Spacing.regular) {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if editor.turnOnPending.contains(key) {
                    Button("Turn On") { retryTurnOn(key) }
                        .buttonStyle(.kitQuiet)
                } else {
                    Button("Reload") { reload(key) }
                        .buttonStyle(.kitQuiet)
                }
            }
        case .confirming, .done, nil:
            EmptyView()
        }
    }

    /// The column's "Keep auto" boxes, held by the center per draft (AUTO-03).
    private func keepAutoBinding(_ key: Int64) -> Binding<Set<String>> {
        let editor = editor
        return Binding(
            get: { editor.keepAuto[key] ?? [] },
            set: { new in
                let old = editor.keepAuto[key] ?? []
                for tool in new.subtracting(old) { editor.setKeepAuto(key, tool: tool, on: true) }
                for tool in old.subtracting(new) { editor.setKeepAuto(key, tool: tool, on: false) }
            }
        )
    }

    private func isFailed(_ key: Int64) -> Bool {
        if case .failed = editor.saving[key] { return true }
        return false
    }

    /// The owner's press: saves or confirms the bytes the column shows,
    /// keeping auto only for the boxes checked (AUTO-03).
    private func press(_ action: AutomationDraftFooter.Action, key: Int64) {
        guard case let .review(plan) = editor.saving[key] else { return }
        var checked = plan
        checked.keepAuto = (editor.keepAuto[key] ?? []).intersection(plan.pausedGrants)
        let editor = editor
        whenLanded {
            switch action {
            case .saveAndTurnOn, .saveAndConfirm:
                await editor.commit(key, plan: checked, turnOn: true)
            case .saveTurnedOff:
                await editor.commit(key, plan: checked, turnOn: false)
            case .confirmAndTurnOn:
                await editor.confirmShown(key, plan: checked, turnOn: true)
            case .confirmTurnedOff, .confirm:
                await editor.confirmShown(key, plan: checked, turnOn: false)
            }
        }
    }

    /// **Turn On** after a save or confirm that did not turn it on.
    private func retryTurnOn(_ key: Int64) {
        let editor = editor
        whenLanded { await editor.retryTurnOn(key) }
    }

    /// Runs `work` to its end — leaving the panel never cancels a save — and
    /// then, if the panel is still here, opens the automation when it is done.
    private func whenLanded(_ work: @escaping @MainActor () async -> Void) {
        pressTask?.cancel()
        pressTask = Task {
            await Task { await work() }.value
            guard !Task.isCancelled else { return }
            if !finishIfSaved() { finishIfConfirmed() }
        }
    }

    // MARK: - Open and finish

    private func open() async {
        if finishIfSaved() || finishIfConfirmed() { return }
        guard chat == nil else { return }
        var made: AutomationEditorChat?
        do {
            made = try await makeChat()
            if made == nil { chatFailure = "This chat can't open: the automation or the database is not available." }
        } catch {
            chatFailure = "This chat can't open: \(error.localizedDescription)"
        }
        guard !Task.isCancelled else {
            made?.close()
            return
        }
        chat = made
        switch target {
        case let .existing(id, _):
            // The form and Script still work when the chat cannot open.
            await editor.beginEdit(id, chatNewestText: made?.draft.shownRecipeText)
        case let .newDraft(_, scope, startText):
            guard let made else { return }
            let key = AutomationEditorCenter.newDraftKey(conversationID: made.conversationID)
            newKey = key
            if finishIfSaved() { return }
            editor.beginNew(key: key, scope: scope, recipeDir: scope.recipeDir(workspaceDir: workspaceDir),
                            startText: startText ?? made.draft.shownRecipeText)
        }
        if let made, let key {
            let editor = editor
            made.setPanelDraft { editor.drafts[key]?.form.renderedText() }
            // Once per draft: a composer the owner emptied stays empty.
            if let prefill = composerPrefill, editor.claimComposerPrefill(key), made.engine.messages.isEmpty,
               made.engine.draft.isEmpty {
                made.engine.draft = prefill
            }
        }
    }

    /// A save that finished (here, or while the panel was away) opens the
    /// saved automation.
    @discardableResult
    private func finishIfSaved() -> Bool {
        guard let key, editor.saving[key] == .done, let savedID = editor.savedIDs[key] else { return false }
        finish(key, savedID)
        return true
    }

    @discardableResult
    private func finishIfConfirmed() -> Bool {
        guard case let .existing(id, _) = target, editor.confirmations[id] == .done else { return false }
        editor.closeConfirmation(id)
        finish(id, id)
        return true
    }

    /// The draft is done with: the next Edit loads the file afresh.
    private func finish(_ key: Int64, _ savedID: Int64) {
        editor.discard(key)
        onSaved(savedID)
    }

    /// A stale confirm: the recipe changed on disk, so the draft is loaded again.
    private func reload(_ key: Int64) {
        editor.closeConfirmation(key)
        editor.discard(key)
        Task { await editor.beginEdit(key, chatNewestText: chat?.draft.shownRecipeText) }
    }
}
