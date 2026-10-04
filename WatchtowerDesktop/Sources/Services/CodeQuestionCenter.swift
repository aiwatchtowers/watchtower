import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Code questions (spec §9.2–§9.4), per workbench, on `AppState`: the ✦
/// button's timing (`AskAIButtonSchedule`), the popover's question
/// (`Session`) and its suggested change, Open Quickly's questions and the
/// inspector's Questions tab. Each conversation is a `CodeQuestionSurface`
/// engine in `EmbeddedChatCenter`, so closing a surface never stops an
/// answer. Every surface gets its engine through `engine(for:)`, the one
/// place that sets the engine's `onTurnFinished` (once per engine), so a
/// conversation shown in two surfaces applies each finished turn once.
@MainActor
@Observable
final class CodeQuestionCenter {
    /// The question the popover shows.
    struct Session {
        let project: Workbench
        let bufferID: String
        /// Moves onto the applied text after Apply.
        var anchor: CodeQuestionAnchor
        /// Gains the usage search's locations before "Where is it used?";
        /// once the conversation exists the center's per-conversation copy
        /// is what the turns read.
        var context: CodeQuestionContext
        var choice: CodeQuestionSurface.ModelChoice
        /// nil until the first question is sent: an opened and dismissed
        /// popover leaves no empty conversation behind.
        var conversationID: Int64?
        var draft = ""
        /// The suggested change on screen as an inline diff.
        var proposal: String?
        var notice: String?
        /// "Where is it used?" is searching before it sends.
        var isSearchingUsages = false
    }

    static let appliedNotice = "Applied. ⌘Z in the editor takes it back."

    private(set) var sessions: [Int64: Session] = [:]
    /// Where the ✦ button shows, in the page's points; none = hidden.
    private(set) var buttonRects: [Int64: CGRect] = [:]
    /// Per workbench: the conversation the Questions tab shows; none = the
    /// list.
    private(set) var inspectorQuestions: [Int64: Int64] = [:]
    /// Per workbench: the Questions tab's rows, newest first.
    private(set) var questionLists: [Int64: [CodeQuestionListItem]] = [:]
    /// Per workbench: why the list could not be read or changed.
    private(set) var questionListErrors: [Int64: String] = [:]
    /// Workbenches whose shown error is a failed read of the list.
    @ObservationIgnored private var questionListReadFailed: Set<Int64> = []
    /// Per conversation: the model pick the Questions tab shows.
    private(set) var modelChoices: [Int64: CodeQuestionSurface.ModelChoice] = [:]
    @ObservationIgnored weak var workbenches: WorkbenchesViewModel?
    @ObservationIgnored weak var navigation: CodeNavigationCenter?
    @ObservationIgnored weak var codeIndex: CodeIndexCenter?
    @ObservationIgnored var embeddedChats: EmbeddedChatCenter?
    @ObservationIgnored var dbPool: DatabasePool?
    @ObservationIgnored var modelSuggestions: (AIProvider) -> [String] = { _ in [] }
    @ObservationIgnored weak var dictation: DictationCenter?
    /// The Files pane inspector, which Pin to inspector opens on Questions.
    @ObservationIgnored weak var usages: CodeUsagesCenter?
    /// Hand to Claude Code (⌥⌘↩, spec §9.5).
    @ObservationIgnored weak var handoff: CodeHandoffCenter?
    @ObservationIgnored private var pages: [Int64: WeakQuestionPage] = [:]
    /// Per conversation: the surfaces' common view of it.
    @ObservationIgnored private var questionRefs: [Int64: CodeQuestionRef] = [:]
    /// Per conversation: the context every turn's system prompt carries
    /// (ruling R41); absent while a reopened question's file is read.
    @ObservationIgnored private var questionContexts: [Int64: CodeQuestionContext] = [:]
    /// Conversations whose attached usages no completed turn has carried
    /// yet: a turn resuming a provider session adds them to its prompt, a
    /// Retry included (ruling R45).
    @ObservationIgnored private var pendingUsageTurns: Set<Int64> = []
    /// Per conversation: the engine whose `onTurnFinished` this center set.
    @ObservationIgnored private var ownedEngines: [Int64: WeakChatEngine] = [:]
    @ObservationIgnored private var selections: [Int64: CodeEditorSelection] = [:]
    @ObservationIgnored private var schedules: [Int64: AskAIButtonSchedule] = [:]
    /// Per workbench: the wait before the ✦ shows (tests await it).
    @ObservationIgnored private(set) var settleTasks: [Int64: Task<Void, Never>] = [:]
    /// Per workbench: bumped by every selection or scroll, so a settle
    /// that an event overtook shows nothing.
    @ObservationIgnored private var settleGenerations: [Int64: Int] = [:]
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private let beep: @MainActor () -> Void
    @ObservationIgnored private let defaultChoice: @MainActor () -> CodeQuestionSurface.ModelChoice
    /// "Where is it used?"'s searches, per workbench.
    @ObservationIgnored private let usageSearches: CodeQuestionUsageSearches

    init(
        clock: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        beep: @escaping @MainActor () -> Void = { NSSound.beep() },
        defaultChoice: @escaping @MainActor () -> CodeQuestionSurface.ModelChoice = { CodeQuestionSurface.defaultModelChoice() },
        startSearch: @escaping CodeSearchStarter = { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, onMatch: onMatch, onDone: onDone)
        }
    ) {
        usageSearches = CodeQuestionUsageSearches(startSearch: startSearch)
        self.clock = clock
        self.sleep = sleep
        self.beep = beep
        self.defaultChoice = defaultChoice
    }

    // MARK: Pages

    func registerPage(_ page: CodeQuestionPage, for workbenchID: Int64) {
        pages[workbenchID] = WeakQuestionPage(page: page)
    }

    /// The Files pane went: its popover and button go; the conversation
    /// stays.
    func unregisterPage(_ page: CodeQuestionPage, for workbenchID: Int64) {
        guard pages[workbenchID]?.page === page else { return }
        pages[workbenchID] = nil
        sessions[workbenchID] = nil
        cancelUsageSearch(workbenchID)
        selections[workbenchID] = nil
        schedules[workbenchID] = nil
        buttonRects[workbenchID] = nil
        settleTasks.removeValue(forKey: workbenchID)?.cancel()
    }

    // MARK: The ✦ button

    /// The page's `selection` message.
    func selectionChanged(_ selection: CodeEditorSelection, workbenchID: Int64) {
        selections[workbenchID] = selection
        schedules[workbenchID, default: AskAIButtonSchedule()].selectionChanged(hasSelection: !selection.isEmpty, at: clock())
        unsettle(workbenchID)
    }

    /// The page's `scroll` message.
    func editorScrolled(workbenchID: Int64) {
        schedules[workbenchID, default: AskAIButtonSchedule()].scrolled(at: clock())
        unsettle(workbenchID)
    }

    /// No file on screen any more: no selection either.
    func editorCleared(workbenchID: Int64) {
        selections[workbenchID] = nil
        schedules[workbenchID, default: AskAIButtonSchedule()].selectionChanged(hasSelection: false, at: clock())
        unsettle(workbenchID)
    }

    private func unsettle(_ workbenchID: Int64) {
        buttonRects[workbenchID] = nil
        settleGenerations[workbenchID, default: 0] += 1
        settleTasks.removeValue(forKey: workbenchID)?.cancel()
        guard let deadline = schedules[workbenchID]?.deadline else { return }
        let generation = settleGenerations[workbenchID]
        let wait = max(0, deadline.timeIntervalSince(clock()))
        settleTasks[workbenchID] = Task { [weak self] in
            await self?.sleep(wait)
            await self?.settle(workbenchID, generation: generation)
        }
    }

    private func settle(_ workbenchID: Int64, generation: Int?) async {
        guard settleGenerations[workbenchID] == generation, !Task.isCancelled else { return }
        settleTasks[workbenchID] = nil
        schedules[workbenchID]?.tick(at: clock())
        guard schedules[workbenchID]?.isVisible == true, let page = pages[workbenchID]?.page else { return }
        let rect = await page.selectionRect()
        // A selection or scroll while the page answered wins.
        guard settleGenerations[workbenchID] == generation, schedules[workbenchID]?.isVisible == true else { return }
        buttonRects[workbenchID] = rect
    }

    // MARK: Asking

    /// ⌘I from the menu: the page posts its selection, then `askAI`.
    func askAIFromMenu(project: Workbench) async {
        guard let page = pages[project.id]?.page, await page.requestAskAI() else {
            beep()
            return
        }
    }

    /// The page's `askAI` (⌘I in the editor, the context menu, the ✦
    /// button, the menu): a popover for the selection, or for the cursor
    /// line when nothing is selected. One question at a time per
    /// workbench: while a popover is open this does nothing.
    func askAI(bufferID: String, project: Workbench) async {
        let workbenchID = project.id
        guard sessions[workbenchID] == nil else { return }
        guard let files = workbenches?.codeFiles, let buffer = files.buffer(id: bufferID), buffer.state == .loaded,
              let page = pages[workbenchID]?.page else {
            beep()
            return
        }
        let selection = selections[workbenchID].flatMap { $0.bufferID == bufferID ? $0 : nil }
        let cursor = files.cursors[workbenchID].flatMap { $0.path == buffer.relPath ? $0.line : nil }
        let anchor = CodeQuestionAnchor.make(path: buffer.relPath, selection: selection,
                                             cursorLine: cursor ?? selection?.range.startLine ?? 1, fileText: buffer.text)
        let index = codeIndex?.index(for: workbenchID)
        let context = CodeQuestionContext.build(
            folderName: project.folderURL.lastPathComponent, origin: anchor.origin,
            language: (buffer.relPath as NSString).pathExtension.lowercased(), fileText: buffer.text
        ) { index?.symbols(named: $0) ?? [] }
        sessions[workbenchID] = Session(project: project, bufferID: bufferID, anchor: anchor, context: context,
                                        choice: defaultChoice())
        schedules[workbenchID, default: AskAIButtonSchedule()].suppress()
        buttonRects[workbenchID] = nil
        let rect = await page.selectionRect()
        guard sessions[workbenchID] != nil else { return }
        guard page.presentQuestionPopover(at: rect ?? CGRect(x: 40, y: 40, width: 1, height: 1)) else {
            // No popover, no question: the next ⌘I or ✦ must be able to ask.
            questionPopoverClosed(workbenchID: workbenchID)
            beep()
            return
        }
    }

    func setDraft(_ text: String, workbenchID: Int64) {
        sessions[workbenchID]?.draft = text
    }

    /// The draft (before the conversation exists) or a quick action's
    /// prompt; true when the turn was handed to the engine.
    @discardableResult
    func ask(_ text: String, workbenchID: Int64) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, var session = sessions[workbenchID] else { return false }
        if session.conversationID == nil {
            guard let dbPool else {
                sessions[workbenchID]?.notice = "Couldn't start the question: the database is not open."
                return false
            }
            let conversationID: Int64
            do {
                conversationID = try CodeQuestionSurface.createConversation(
                    workbenchID: workbenchID, origin: session.anchor.origin, choice: session.choice, dbPool: dbPool)
            } catch {
                NSLog("CodeQuestionCenter: creating a code question: %@", error.localizedDescription)
                sessions[workbenchID]?.notice = "Couldn't start the question: \(error.localizedDescription)"
                return false
            }
            session.conversationID = conversationID
            session.draft = ""
            session.notice = nil
            sessions[workbenchID] = session
            questionRefs[conversationID] = CodeQuestionRef(project: session.project, conversationID: conversationID,
                                                           origin: session.anchor.origin)
            questionContexts[conversationID] = session.context
            modelChoices[conversationID] = session.choice
        }
        guard let engine = engine(workbenchID: workbenchID) else { return false }
        guard engine.send(question) else {
            sessions[workbenchID]?.notice = "Wait for the answer to finish, then ask again."
            return false
        }
        sessions[workbenchID]?.notice = nil
        return true
    }

    func quickAction(_ action: CodeQuestionQuickAction, workbenchID: Int64) {
        guard action == .whereUsed else {
            ask(action.prompt, workbenchID: workbenchID)
            return
        }
        askWhereUsed(workbenchID: workbenchID)
    }

    // MARK: Where is it used? (ruling R45)

    /// Searches the selected identifier (else the one at the cursor) with
    /// `code search --word --case`, attaches up to 30 locations to the
    /// question's context, then sends; without a name it sends at once.
    private func askWhereUsed(workbenchID: Int64) {
        guard let session = sessions[workbenchID], !session.isSearchingUsages else { return }
        let prompt = CodeQuestionQuickAction.whereUsed.prompt
        let buffer = workbenches?.codeFiles.buffer(id: session.bufferID)
        let cursor = workbenches?.codeFiles.cursors[workbenchID].flatMap { $0.path == session.anchor.path ? $0 : nil }
        let anchorLine = session.anchor.isSelection ? session.anchor.range.endLine : session.anchor.range.startLine
        guard let buffer, let name = session.anchor.usageName(
            cursorCol: cursor.flatMap { $0.line == anchorLine ? $0.col : nil }, fileText: buffer.text) else {
            ask(prompt, workbenchID: workbenchID)
            return
        }
        sessions[workbenchID]?.isSearchingUsages = true
        usageSearches.start(name: name, folder: session.project.folderURL, workbenchID: workbenchID) { [weak self] usages in
            guard let self else { return }
            sessions[workbenchID]?.isSearchingUsages = false
            let before = attachedUsages(workbenchID: workbenchID)
            if let usages { attachUsages(usages, pending: true, workbenchID: workbenchID) }
            // Not sent (a follow-up from the composer is running, say): the
            // usages go with it, so no unrelated turn carries them.
            if !ask(prompt, workbenchID: workbenchID) {
                attachUsages(before.usages, pending: before.pending, workbenchID: workbenchID)
            }
        }
    }

    private func attachedUsages(workbenchID: Int64) -> (usages: CodeQuestionUsages?, pending: Bool) {
        let session = sessions[workbenchID]
        let pending = session?.conversationID.map { pendingUsageTurns.contains($0) } ?? false
        return (session?.context.usages, pending)
    }

    /// The popover's question and, once it exists, its conversation's
    /// context the turns read.
    private func attachUsages(_ usages: CodeQuestionUsages?, pending: Bool, workbenchID: Int64) {
        sessions[workbenchID]?.context.usages = usages
        guard let conversationID = sessions[workbenchID]?.conversationID else { return }
        questionContexts[conversationID]?.usages = usages
        if pending {
            pendingUsageTurns.insert(conversationID)
        } else {
            pendingUsageTurns.remove(conversationID)
        }
    }

    private func cancelUsageSearch(_ workbenchID: Int64) {
        usageSearches.cancel(workbenchID)
        sessions[workbenchID]?.isSearchingUsages = false
    }

    /// App quit (ruling R34): every usage search is killed with its process
    /// group.
    func stopQuestionSearches() {
        usageSearches.cancelAll()
        for workbenchID in Array(sessions.keys) { sessions[workbenchID]?.isSearchingUsages = false }
    }

    /// The usages a resumed turn adds to its prompt, until a turn carrying
    /// them completes (a failed one's Retry carries them again).
    private func usageAttachment(conversationID: Int64) -> String? {
        guard pendingUsageTurns.contains(conversationID) else { return nil }
        return questionContexts[conversationID]?.usagesBlock
    }

    // MARK: Engines

    /// The popover's conversation's engine, once the first question was sent.
    func engine(workbenchID: Int64) -> EmbeddedChatEngine? {
        guard let conversationID = sessions[workbenchID]?.conversationID,
              let question = questionRefs[conversationID] else { return nil }
        return engine(for: question)
    }

    /// Every surface's engine for a code question. The engine's
    /// `onTurnFinished` is this center's, set once per engine (a body pass
    /// asking again changes nothing; an engine made again after a release
    /// gets it again).
    func engine(for question: CodeQuestionRef) -> EmbeddedChatEngine? {
        guard let embeddedChats, let dbPool else { return nil }
        let conversationID = question.conversationID
        questionRefs[conversationID] = question
        let engine = embeddedChats.engine(for: CodeQuestionSurface.spec(
            workbench: question.project, origin: question.origin, conversationID: conversationID, dbPool: dbPool,
            context: { [weak self] in self?.questionContexts[conversationID] },
            turnAttachment: { [weak self] in self?.usageAttachment(conversationID: conversationID) }
        ))
        if ownedEngines[conversationID]?.engine !== engine {
            ownedEngines[conversationID] = WeakChatEngine(engine: engine)
            engine.onTurnFinished = { [weak self] outcome in
                self?.turnFinished(outcome, conversationID: conversationID)
            }
        }
        return engine
    }

    func questionRef(_ conversationID: Int64) -> CodeQuestionRef? {
        questionRefs[conversationID]
    }

    /// Whether the turns of a conversation carry its code context yet.
    func hasContext(conversationID: Int64) -> Bool {
        questionContexts[conversationID] != nil
    }

    // MARK: Model

    /// The popover's model picker: kept on the conversation once it exists.
    func setModelChoice(_ choice: CodeQuestionSurface.ModelChoice, workbenchID: Int64) {
        guard let session = sessions[workbenchID] else { return }
        if let conversationID = session.conversationID {
            if let failure = storeModelChoice(choice, conversationID: conversationID) {
                sessions[workbenchID]?.notice = failure
            }
            return
        }
        sessions[workbenchID]?.choice = choice
    }

    /// The Questions tab's model picker.
    func setModelChoice(_ choice: CodeQuestionSurface.ModelChoice, conversationID: Int64) {
        let failure = storeModelChoice(choice, conversationID: conversationID)
        guard let workbenchID = questionRefs[conversationID]?.project.id else { return }
        if let failure {
            showActionError(failure, workbenchID: workbenchID)
        } else {
            clearActionError(workbenchID: workbenchID)
        }
    }

    /// An action failed: its note replaces whatever was shown, and a list
    /// read does not clear it.
    private func showActionError(_ message: String, workbenchID: Int64) {
        questionListReadFailed.remove(workbenchID)
        questionListErrors[workbenchID] = message
    }

    /// An action went through: its earlier failure's note goes (a failed
    /// read's stays until the list reads again).
    private func clearActionError(workbenchID: Int64) {
        guard !questionListReadFailed.contains(workbenchID) else { return }
        questionListErrors[workbenchID] = nil
    }

    func modelChoice(conversationID: Int64) -> CodeQuestionSurface.ModelChoice {
        modelChoices[conversationID] ?? defaultChoice()
    }

    /// Writes the pick, then shows it everywhere; the failure's text when it
    /// could not be stored.
    private func storeModelChoice(_ choice: CodeQuestionSurface.ModelChoice, conversationID: Int64) -> String? {
        guard let dbPool else { return "Couldn't change the model: the database is not open." }
        do {
            try CodeQuestionSurface.setModelChoice(choice, conversationID: conversationID, dbPool: dbPool)
        } catch {
            NSLog("CodeQuestionCenter: storing the model: %@", error.localizedDescription)
            return "Couldn't change the model: \(error.localizedDescription)"
        }
        modelChoices[conversationID] = choice
        for (workbenchID, session) in sessions where session.conversationID == conversationID {
            sessions[workbenchID]?.choice = choice
        }
        return nil
    }

    // MARK: Suggested change

    /// The one turn-finished handler of a code question's engine: a
    /// completed turn has carried the attached usages; a completed answer
    /// with a `wt-edit` block shows its change as an inline diff over what
    /// the popover's question was about.
    private func turnFinished(_ outcome: EmbeddedChatEngine.TurnOutcome, conversationID: Int64) {
        guard let workbenchID = questionRefs[conversationID]?.project.id else { return }
        guard case let .completed(_, result) = outcome else { return }
        pendingUsageTurns.remove(conversationID)
        guard let session = sessions[workbenchID], session.conversationID == conversationID,
              let replacement = WtEditBlock.replacement(in: result.displayText) else { return }
        // A selection the page cut, or one whose lines the context cut,
        // cannot be replaced by an answer that never saw all of it.
        guard session.anchor.canApply, questionContexts[conversationID]?.focusWasCut != true else {
            sessions[workbenchID]?.notice = CodeEditApplyRefusal.selectionTooLarge.message
            return
        }
        let fitted = WtEditBlock.fitted(replacement, toReplace: session.anchor.originalText)
        sessions[workbenchID]?.proposal = fitted
        sessions[workbenchID]?.notice = nil
        pages[workbenchID]?.page?.proposeEdit(bufferID: session.bufferID, range: session.anchor.range, text: fitted)
    }

    /// Apply: one undoable edit in the editor, then the usual autosave and
    /// PROJ-03 rules. Refused while the file has a problem with its disk
    /// version, and when the text changed since the question.
    func applyProposal(workbenchID: Int64) async {
        guard let session = sessions[workbenchID], let proposal = session.proposal else { return }
        let buffer = workbenches?.codeFiles.buffer(id: session.bufferID)
        if let refusal = session.anchor.applyRefusal(fileProblem: buffer?.problem?.message) {
            sessions[workbenchID]?.notice = refusal.message
            return
        }
        guard buffer != nil, let page = pages[workbenchID]?.page else {
            sessions[workbenchID]?.notice = CodeEditApplyRefusal.editorClosed.message
            return
        }
        let result = await page.applyEdit(bufferID: session.bufferID, range: session.anchor.range, text: proposal,
                                          expected: session.anchor.originalText)
        guard sessions[workbenchID] != nil else { return }
        if let refusal = CodeEditApplyRefusal(pageResult: result) {
            sessions[workbenchID]?.notice = refusal.message
        } else {
            sessions[workbenchID]?.anchor = session.anchor.applied(proposal)
            sessions[workbenchID]?.proposal = nil
            sessions[workbenchID]?.notice = Self.appliedNotice
        }
    }

    func discardProposal(workbenchID: Int64) {
        guard let session = sessions[workbenchID], session.proposal != nil else { return }
        pages[workbenchID]?.page?.clearProposal(bufferID: session.bufferID)
        sessions[workbenchID]?.proposal = nil
    }

    // MARK: Closing and links

    /// Esc or a link click: the popover goes; the conversation stays.
    func closeQuestion(workbenchID: Int64) {
        pages[workbenchID]?.page?.closeQuestionPopover()
        questionPopoverClosed(workbenchID: workbenchID)
    }

    /// The popover closed (Esc, a click outside): its diff goes with it.
    func questionPopoverClosed(workbenchID: Int64) {
        cancelUsageSearch(workbenchID)
        guard let session = sessions.removeValue(forKey: workbenchID) else { return }
        if session.proposal != nil { pages[workbenchID]?.page?.clearProposal(bufferID: session.bufferID) }
        schedules[workbenchID, default: AskAIButtonSchedule()].resume(at: clock())
        unsettle(workbenchID)
    }

    /// A `path:line` link in the popover's answer: the popover closes and
    /// the file opens.
    func openLink(_ url: URL, workbenchID: Int64) async {
        guard let project = sessions[workbenchID]?.project else {
            beep()
            return
        }
        await openLink(url, project: project) { closeQuestion(workbenchID: workbenchID) }
    }

    /// A `path:line` link in an answer: the file in the Files pane, if it is
    /// a file of the workbench (after `beforeOpening`, which closes the
    /// surface it was clicked in); where the cursor was goes on Back. Else
    /// a beep and false. A symlink leaving the folder is refused before its
    /// target is looked at (`WorkbenchFolderPath`, board #361).
    @discardableResult
    func openLink(_ url: URL, project: Workbench, beforeOpening: () -> Void = {}) async -> Bool {
        guard let target = CodeLineLinks.target(from: url),
              WorkbenchFolderPath.resolve(target.path, folder: project.folderPath) != nil else {
            beep()
            return false
        }
        beforeOpening()
        navigation?.recordJumpFromCurrentLocation(project: project)
        await workbenches?.openFile(at: target, project: project, beside: false)
        return true
    }

    // MARK: Open Quickly (spec §9.3)

    /// ⌘↩ or the ✦ Ask AI row: a new conversation about the query, with no
    /// selection — the open file (path, language, the cursor line and ±40
    /// lines) is its context, `<wb>:<path>:<cursor line>` its `context_id`;
    /// with no file open the context is the folder only and the id
    /// `<wb>::0`. The answer shows in the panel.
    func askFromOpenQuickly(_ query: String, project: Workbench) -> CodeQuestionStart {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .failed("Type a question first.") }
        guard let dbPool else { return .failed("Couldn't start the question: the database is not open.") }
        let (origin, context) = openFileContext(project)
        let choice = defaultChoice()
        let conversationID: Int64
        do {
            conversationID = try CodeQuestionSurface.createConversation(
                workbenchID: project.id, origin: origin, choice: choice, dbPool: dbPool)
        } catch {
            NSLog("CodeQuestionCenter: creating a code question: %@", error.localizedDescription)
            return .failed("Couldn't start the question: \(error.localizedDescription)")
        }
        questionContexts[conversationID] = context
        modelChoices[conversationID] = choice
        let conversation = CodeQuestionRef(project: project, conversationID: conversationID, origin: origin)
        guard let engine = engine(for: conversation), engine.send(question) else {
            // Nothing was sent: no empty conversation stays behind.
            discardConversation(conversation)
            return .failed("Couldn't send the question.")
        }
        return .started(conversationID: conversationID)
    }

    /// Where Open Quickly's question is about: the Files pane's active file
    /// at the cursor line, or no file (⌥⌘↩'s hand-off, spec §9.5).
    func openFileOrigin(_ project: Workbench) -> CodeQuestionOrigin {
        openFileContext(project).0
    }

    /// The Files pane's active file at the cursor line (line 1 when the
    /// cursor is elsewhere); its context once the file is loaded.
    private func openFileContext(_ project: Workbench) -> (CodeQuestionOrigin, CodeQuestionContext?) {
        guard let files = workbenches?.codeFiles, let path = files.tabs(for: project).active else {
            return (CodeQuestionOrigin(path: "", line: 0, selection: nil), nil)
        }
        let line = files.cursors[project.id].flatMap { $0.path == path ? $0.line : nil } ?? 1
        let origin = CodeQuestionOrigin(path: path, line: line, selection: nil)
        guard let buffer = files.existingBuffer(project, path), buffer.state == .loaded else { return (origin, nil) }
        return (origin, context(origin: origin, project: project, fileText: buffer.text))
    }

    private func context(origin: CodeQuestionOrigin, project: Workbench, fileText: String) -> CodeQuestionContext {
        let index = codeIndex?.index(for: project.id)
        return CodeQuestionContext.build(
            folderName: project.folderURL.lastPathComponent, origin: origin,
            language: (origin.path as NSString).pathExtension.lowercased(), fileText: fileText
        ) { index?.symbols(named: $0) ?? [] }
    }

    // MARK: Questions tab (spec §9.4)

    /// The Questions tab while it shows (the view's task): the list follows
    /// every write to the questions — one asked, a turn streamed, a delete —
    /// through a GRDB observation. The app writes them all but two: the
    /// CLI's workbench delete (`workbenchRemoved` clears that list) and a
    /// migration, before any view shows. A new list clears only a read
    /// error; an action's error stays until the next action.
    func observeQuestionList(workbenchID: Int64) async {
        guard let dbPool else { return }
        let observation = ValueObservation.tracking { try CodeQuestionList.fetch($0, workbenchID: workbenchID) }
            .removeDuplicates()
        do {
            for try await items in observation.values(in: dbPool) {
                questionLists[workbenchID] = items
                if questionListReadFailed.remove(workbenchID) != nil { questionListErrors[workbenchID] = nil }
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("CodeQuestionCenter: watching the code questions: %@", error.localizedDescription)
            questionListReadFailed.insert(workbenchID)
            questionListErrors[workbenchID] = "Couldn't read the questions: \(error.localizedDescription)"
        }
    }

    /// Reads the workbench's questions, newest first, once.
    func reloadQuestionList(workbenchID: Int64) {
        guard let dbPool else { return }
        do {
            questionLists[workbenchID] = try dbPool.read { try CodeQuestionList.fetch($0, workbenchID: workbenchID) }
            if questionListReadFailed.remove(workbenchID) != nil { questionListErrors[workbenchID] = nil }
        } catch {
            NSLog("CodeQuestionCenter: reading the code questions: %@", error.localizedDescription)
            questionListReadFailed.insert(workbenchID)
            questionListErrors[workbenchID] = "Couldn't read the questions: \(error.localizedDescription)"
        }
    }

    /// A row's click: the conversation in the inspector. A question reopened
    /// with no context in memory (after a restart) gets it back from its
    /// file around its line (ruling R41; the selection itself is not stored).
    func openQuestion(_ item: CodeQuestionListItem, project: Workbench) {
        let question = CodeQuestionRef(project: project, conversationID: item.conversationID, origin: item.origin)
        questionRefs[item.conversationID] = question
        inspectorQuestions[project.id] = item.conversationID
        loadModelChoice(conversationID: item.conversationID)
        rebuildContextIfNeeded(question)
    }

    /// Back to the list.
    func closeInspectorQuestion(workbenchID: Int64) {
        inspectorQuestions[workbenchID] = nil
    }

    /// Pin to inspector: the popover's conversation moves to the Questions
    /// tab with its engine (a running answer keeps streaming there).
    func pinToInspector(workbenchID: Int64) {
        guard let session = sessions[workbenchID], let conversationID = session.conversationID,
              !session.isSearchingUsages else { return }
        modelChoices[conversationID] = session.choice
        inspectorQuestions[workbenchID] = conversationID
        usages?.setInspectorShown(true, workbenchID: workbenchID)
        usages?.selectInspectorTab(.questions, workbenchID: workbenchID)
        closeQuestion(workbenchID: workbenchID)
        reloadQuestionList(workbenchID: workbenchID)
    }

    // MARK: Hand to Claude Code (spec §9.5)

    /// The popover's ⌥⌘↩: it closes and its conversation goes to the
    /// page's hand-off sheet. Not while an answer streams (the button is
    /// disabled then too), nor before the first question.
    func handToClaude(workbenchID: Int64) {
        guard let conversationID = sessions[workbenchID]?.conversationID, let question = questionRefs[conversationID] else {
            beep()
            return
        }
        handToClaude(question) { closeQuestion(workbenchID: workbenchID) }
    }

    /// The Questions tab's ⌥⌘↩ on the open conversation, and the popover's
    /// after `beforeHanding` closed it.
    func handToClaude(_ question: CodeQuestionRef, beforeHanding: () -> Void = {}) {
        guard let handoff, engine(for: question)?.isBusy != true else {
            beep()
            return
        }
        beforeHanding()
        Task { await handoff.handConversation(question) }
    }

    /// Delete: the conversation and its messages go, its engine stops
    /// quietly, and the popover or inspector showing it closes. A failed
    /// delete changes nothing and says so.
    func deleteQuestion(_ question: CodeQuestionRef) {
        let workbenchID = question.project.id
        guard let dbPool else { return }
        do {
            try dbPool.write { db in _ = try CodeQuestionList.delete(db, conversationID: question.conversationID) }
        } catch {
            NSLog("CodeQuestionCenter: deleting a code question: %@", error.localizedDescription)
            showActionError("Couldn't delete the question: \(error.localizedDescription)", workbenchID: workbenchID)
            return
        }
        forget(question)
        if sessions[workbenchID]?.conversationID == question.conversationID { closeQuestion(workbenchID: workbenchID) }
        if inspectorQuestions[workbenchID] == question.conversationID { inspectorQuestions[workbenchID] = nil }
        questionLists[workbenchID]?.removeAll { $0.conversationID == question.conversationID }
        clearActionError(workbenchID: workbenchID)
    }

    /// An Open Quickly question that could not be sent: its empty row goes.
    private func discardConversation(_ question: CodeQuestionRef) {
        forget(question)
        guard let dbPool else { return }
        do {
            try dbPool.write { db in _ = try CodeQuestionList.delete(db, conversationID: question.conversationID) }
        } catch {
            NSLog("CodeQuestionCenter: removing an unsent code question: %@", error.localizedDescription)
        }
    }

    /// The workbench was deleted, its code questions with it (PROJ-02): the
    /// popover closes, every engine of its questions stops quietly and the
    /// tab's state goes.
    func workbenchRemoved(_ workbenchID: Int64) {
        if sessions[workbenchID] != nil { closeQuestion(workbenchID: workbenchID) }
        for question in questionRefs.values where question.project.id == workbenchID {
            forget(question)
        }
        inspectorQuestions[workbenchID] = nil
        questionLists[workbenchID] = nil
        questionListErrors[workbenchID] = nil
        questionListReadFailed.remove(workbenchID)
    }

    private func forget(_ question: CodeQuestionRef) {
        let conversationID = question.conversationID
        embeddedChats?.drop(EmbeddedChatKey(
            contextType: CodeQuestionSurface.contextType,
            contextID: question.origin.contextID(workbenchID: question.project.id), conversationID: conversationID))
        questionRefs[conversationID] = nil
        questionContexts[conversationID] = nil
        pendingUsageTurns.remove(conversationID)
        ownedEngines[conversationID] = nil
        modelChoices[conversationID] = nil
    }

    private func loadModelChoice(conversationID: Int64) {
        guard modelChoices[conversationID] == nil, let dbPool else { return }
        do {
            modelChoices[conversationID] = try CodeQuestionSurface.modelChoice(conversationID: conversationID, dbPool: dbPool)
        } catch {
            NSLog("CodeQuestionCenter: reading the model of a code question: %@", error.localizedDescription)
        }
    }

    /// The open buffer's text when the file is loaded, else the file read
    /// off the main actor — only a file of the folder, a symlink leaving it
    /// refused unread (`WorkbenchFolderPath`, board #361); nothing for a
    /// question asked with no file.
    private func rebuildContextIfNeeded(_ question: CodeQuestionRef) {
        let conversationID = question.conversationID
        guard questionContexts[conversationID] == nil, !question.origin.path.isEmpty else { return }
        if let buffer = workbenches?.codeFiles.existingBuffer(question.project, question.origin.path), buffer.state == .loaded {
            questionContexts[conversationID] = context(origin: question.origin, project: question.project, fileText: buffer.text)
            return
        }
        let folder = question.project.folderPath
        let path = question.origin.path
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                Self.readFolderFile(path, folder: folder)
            }.value
            guard let self, let text, questionRefs[conversationID] != nil, questionContexts[conversationID] == nil else { return }
            questionContexts[conversationID] = context(origin: question.origin, project: question.project, fileText: text)
        }
    }

    /// A file of the workbench folder as UTF-8 text; nil when it is not one
    /// (a symlink leaving the folder is refused unread, board #361) or
    /// cannot be read.
    nonisolated static func readFolderFile(_ path: String, folder: String) -> String? {
        guard let real = WorkbenchFolderPath.FileSystem.live.realPath(folder) else {
            NSLog("CodeQuestionCenter: a reopened question's workbench folder is gone: %@", folder)
            return nil
        }
        guard let file = WorkbenchFolderPath.resolve(path, folder: folder, folderRealPath: real) else {
            NSLog("CodeQuestionCenter: a reopened question's file %@ is missing or not a file of its workbench folder", path)
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: real).appendingPathComponent(file))
        } catch {
            NSLog("CodeQuestionCenter: reading a reopened question's file %@: %@", path, error.localizedDescription)
            return nil
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            NSLog("CodeQuestionCenter: a reopened question's file %@ is not UTF-8 text", path)
            return nil
        }
        return text
    }
}

private struct WeakChatEngine {
    weak var engine: EmbeddedChatEngine?
}

private struct WeakQuestionPage {
    weak var page: CodeQuestionPage?
}
