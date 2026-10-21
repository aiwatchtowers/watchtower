import AppKit
import GRDB
import OSLog
import WatchtowerCore

private let inboxLog = Logger(subsystem: Constants.bundleID, category: "inbox")

/// What an Inbox card's buttons do (spec B2): a press emits an
/// `InboxCardCommand` and this carries it out. A failure the owner must see
/// lands in the Inbox's error banner (`actionStripViewModel.lastError`).
extension AppState {
    nonisolated static let inboxNoWorkbench =
        "There is no workbench to hand this card to. Create one in Workbench first."

    /// The workbenches a card can be handed to: the Workbench tab's list.
    var inboxWorkbenches: [Workbench] {
        workbenchesViewModel?.summaries.map(\.project) ?? []
    }

    func perform(_ command: InboxCardCommand) async {
        switch command {
        case .openLink(let url):
            // Checked again at press time: a screen link opens only through
            // `openNavLink`, a web link goes to the system browser.
            switch InboxCardLinkPolicy.route(url, navScreens: visibleHelpScreenIDs) {
            case .screen(let screen): openNavLink(screen)
            case .web(let web): NSWorkspace.shared.open(web)
            case nil: break
            }
        case let .chat(card, message):
            await openChatAboutInboxCard(card, message: message)
        case let .agent(card, task, ref):
            // The card's buttons already showed the picker where one was
            // needed; what still names no workbench is refused.
            switch InboxAgentHandoff.workbench(for: ref, card: card, workbenches: inboxWorkbenches) {
            case .workbench(let id): await handInboxCardToAgent(card, task: task, workbenchID: id)
            case .pick: actionStripViewModel?.lastError = Self.inboxNoWorkbench
            }
        case let .reply(outputID, action):
            await actionStripViewModel?.pressReply(outputID: outputID, action: action)
        case .openAutomation(let card):
            openAutomationRun(automationID: card.automationID, runID: nil)
        }
    }

    /// Discuss in Chat and a Chat action: a new AI Chat with the card
    /// attached as `inbox-card-<id>.md` (the chat reads it as data) and
    /// `message` in the composer, which takes the keyboard. Nothing is sent;
    /// text the owner had typed is kept.
    func openChatAboutInboxCard(_ card: AutomationOutputCard, message: String) async {
        ensureChatViewModels()
        guard let chat = chatViewModel else { return }
        // A failed create says why on the chat itself.
        if await chat.newConversation() != nil {
            let markdown = InboxCardTexts.attachmentMarkdown(card)
            if await !chat.attachPasted(Data(markdown.utf8), name: "inbox-card-\(card.id).md") {
                chat.errorMessage = "Couldn't attach the Inbox card to this chat."
            }
            chat.draft = HelpChatPrefill.merge(draft: chat.draft, prefill: message)
        }
        selectedDestination = .chat
        chat.requestComposerFocus()
    }

    /// Hand to Agent… and an Agent action: a target on `workbenchID`'s board
    /// with the task's first line as its title and the whole task as its
    /// intent, then Work on It (a session starts), on the Workbench tab.
    func handInboxCardToAgent(_ card: AutomationOutputCard, task: String, workbenchID: Int64) async {
        guard let workbenches = workbenchesViewModel, let cli = workbenches.cli else {
            actionStripViewModel?.lastError = "The Workbench is not ready."
            return
        }
        let firstLine = InboxCardTexts.targetTitle(fromTask: task)
        let title = firstLine.isEmpty ? "Inbox card #\(card.id)" : firstLine
        let priority = WorkbenchBoardCard.editablePriorities.contains(card.priority) ? card.priority : "medium"
        let targetID: Int64
        do {
            targetID = try await cli.addTarget(workbenchID: workbenchID, title: title, intent: task,
                                               priority: priority, parentID: nil)
        } catch {
            inboxLog.error("handing card \(card.id) to workbench \(workbenchID): \(error.localizedDescription, privacy: .public)")
            actionStripViewModel?.lastError = "Couldn't create the target: \(error.localizedDescription)"
            return
        }
        selectedDestination = .workbench
        // A failed start is shown on the workbench's own page.
        await workbenches.workOn(targetID: targetID, targetText: title, projectID: workbenchID)
    }

    /// A `save_automation` proposal's **Open Draft**: the recipe it proposes
    /// in the editor panel, unsaved — over the saved automation it replaces,
    /// or as a new draft in its scope. Only the owner's press there saves.
    func openSaveProposalDraft(_ model: SaveAutomationCardModel) {
        let savedID = model.isNew ? nil : savedAutomationID(path: model.path)
        switch SaveProposalDraftOpening(model: model, savedID: savedID, workbenches: inboxWorkbenches) {
        case .existing(let id):
            openAutomationEditor(.existing(id, startText: model.recipeText))
        case .newDraft(let scope):
            openAutomationDraft(text: model.recipeText, scope: scope)
        case .workbenchGone(let id):
            actionStripViewModel?.lastError = "The workbench of this automation (#\(id)) is gone."
        }
    }

    private func savedAutomationID(path: String) -> Int64? {
        guard !path.isEmpty, let pool = databaseManager?.dbPool else { return nil }
        do {
            return try pool.read { db in try AutomationQueries.automationID(db, path: path) }
        } catch {
            inboxLog.error("reading the automation at a proposal's path: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
