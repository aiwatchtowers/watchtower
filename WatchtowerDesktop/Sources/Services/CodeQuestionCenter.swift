import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The editor page's half of code questions (spec §9.2, §8.5): the Files
/// pane's `MonacoEditorView.Coordinator`, a fake in tests.
@MainActor
protocol CodeQuestionPage: AnyObject {
    /// `askAI()`: the page posts `selection`, then `askAI`, for the file on
    /// screen; false = no file (or the page could not be asked).
    func requestAskAI() async -> Bool
    /// The selection's box (a caret's when empty) in the page's points, top
    /// left origin; nil = no file on screen or scrolled away.
    func selectionRect() async -> CGRect?
    func proposeEdit(bufferID: String, range: CodeTextRange, text: String)
    func clearProposal(bufferID: String)
    func applyEdit(bufferID: String, range: CodeTextRange, text: String, expected: String) async -> CodeEditApplyResult
    /// The question popover, pointing at `rect` (page points); false when
    /// it could not be shown (the editor is in no window).
    func presentQuestionPopover(at rect: CGRect) -> Bool
    func closeQuestionPopover()
}

/// The popover's quick actions (spec §9.2): each sends a fixed prompt.
enum CodeQuestionQuickAction: CaseIterable, Identifiable {
    case explain
    case findProblems
    case whereUsed
    case suggestChange

    var id: Self { self }

    var title: String {
        switch self {
        case .explain: "Explain"
        case .findProblems: "Find problems"
        case .whereUsed: "Where is it used?"
        case .suggestChange: "Suggest a change"
        }
    }

    var prompt: String {
        switch self {
        case .explain: "Explain what this code does."
        case .findProblems: "Find problems in this code: bugs, unhandled cases and risky assumptions."
        case .whereUsed: "Where is this used? Answer only from the usage locations attached to this question "
            + "(Watchtower's search of the workbench), citing each as path:line; say so when none are attached."
        case .suggestChange: "Suggest a change to this code."
        }
    }
}

/// A code question's conversation as every surface opens it: the popover,
/// Open Quickly's answer card and the Questions tab.
struct CodeQuestionRef {
    let project: Workbench
    let conversationID: Int64
    /// What `context_id` names; `path` "" for Open Quickly with no file open.
    let origin: CodeQuestionOrigin
}

/// What asking from Open Quickly did.
enum CodeQuestionStart: Equatable {
    case started(conversationID: Int64)
    case failed(String)
}

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
    @ObservationIgnored private var settleTasks: [Int64: Task<Void, Never>] = [:]
    /// Per workbench: bumped by every selection or scroll, so a settle
    /// that an event overtook shows nothing.
    @ObservationIgnored private var settleGenerations: [Int64: Int] = [:]
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void
    @ObservationIgnored private let beep: @MainActor () -> Void
    @ObservationIgnored private let defaultChoice: @MainActor () -> CodeQuestionSurface.ModelChoice
    @ObservationIgnored private let startSearch: CodeSearchStarter
    /// Per workbench: the "Where is it used?" search; a newer question's
    /// generation drops an older search's callbacks.
    @ObservationIgnored private var usageSearches: [Int64: CodeSearchCancelling] = [:]
    @ObservationIgnored private var usageGenerations: [Int64: Int] = [:]
    @ObservationIgnored private var nextUsageGeneration = 0

    init(
        clock: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        beep: @escaping @MainActor () -> Void = { NSSound.beep() },
        defaultChoice: @escaping @MainActor () -> CodeQuestionSurface.ModelChoice = { CodeQuestionSurface.defaultModelChoice() },
        startSearch: @escaping CodeSearchStarter = { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, onMatch: onMatch, onDone: onDone)
        }
    ) {
        self.startSearch = startSearch
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
        refreshQuestionList(workbenchID: workbenchID)
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
        cancelUsageSearch(workbenchID)
        nextUsageGeneration += 1
        let generation = nextUsageGeneration
        usageGenerations[workbenchID] = generation
        sessions[workbenchID]?.isSearchingUsages = true
        var found: [CodeQuestionUsages.Location] = []
        let options = CodeSearchOptions(query: name, word: true, caseSensitive: true,
                                        max: CodeQuestionUsages.limit, context: 0)
        usageSearches[workbenchID] = startSearch(session.project.folderURL, options, { [weak self] match in
            guard self?.usageGenerations[workbenchID] == generation, found.count < CodeQuestionUsages.limit else { return }
            found.append(CodeQuestionUsages.Location(path: match.path, line: match.line, text: match.text))
        }, { [weak self] outcome in
            guard let self, usageGenerations[workbenchID] == generation else { return }
            usageGenerations[workbenchID] = nil
            usageSearches[workbenchID] = nil
            sessions[workbenchID]?.isSearchingUsages = false
            let before = attachedUsages(workbenchID: workbenchID)
            switch outcome {
            case let .finished(done):
                let usages = CodeQuestionUsages(name: name, locations: found,
                                                truncated: done.truncated || found.count >= CodeQuestionUsages.limit)
                attachUsages(usages, pending: true, workbenchID: workbenchID)
            case let .failed(message):
                NSLog("CodeQuestionCenter: the usage search for a code question failed: %@", message)
            }
            // Not sent (a follow-up from the composer is running, say): the
            // usages go with it, so no unrelated turn carries them.
            if !ask(prompt, workbenchID: workbenchID) {
                attachUsages(before.usages, pending: before.pending, workbenchID: workbenchID)
            }
        })
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
        usageGenerations[workbenchID] = nil
        usageSearches.removeValue(forKey: workbenchID)?.cancel()
        sessions[workbenchID]?.isSearchingUsages = false
    }

    /// App quit (ruling R34): every usage search is killed with its process
    /// group.
    func stopQuestionSearches() {
        for workbenchID in Array(usageSearches.keys) { cancelUsageSearch(workbenchID) }
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
        guard let failure = storeModelChoice(choice, conversationID: conversationID),
              let workbenchID = questionRefs[conversationID]?.project.id else { return }
        questionListErrors[workbenchID] = failure
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
    /// completed turn has carried the attached usages; the list shows the
    /// new state; a completed answer with a `wt-edit` block shows its change
    /// as an inline diff over what the popover's question was about.
    private func turnFinished(_ outcome: EmbeddedChatEngine.TurnOutcome, conversationID: Int64) {
        guard let workbenchID = questionRefs[conversationID]?.project.id else { return }
        refreshQuestionList(workbenchID: workbenchID)
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
    /// a beep and false.
    @discardableResult
    func openLink(_ url: URL, project: Workbench, beforeOpening: () -> Void = {}) async -> Bool {
        guard let target = CodeLineLinks.target(from: url) else {
            beep()
            return false
        }
        var isDirectory: ObjCBool = false
        let file = project.folderURL.appendingPathComponent(target.path)
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
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
        refreshQuestionList(workbenchID: project.id)
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

    /// Reads the workbench's questions, newest first.
    func reloadQuestionList(workbenchID: Int64) {
        guard let dbPool else { return }
        do {
            questionLists[workbenchID] = try dbPool.read { try CodeQuestionList.fetch($0, workbenchID: workbenchID) }
            questionListErrors[workbenchID] = nil
        } catch {
            NSLog("CodeQuestionCenter: reading the code questions: %@", error.localizedDescription)
            questionListErrors[workbenchID] = "Couldn't read the questions: \(error.localizedDescription)"
        }
    }

    /// A list the tab has shown follows new questions and turns.
    private func refreshQuestionList(workbenchID: Int64) {
        guard questionLists[workbenchID] != nil else { return }
        reloadQuestionList(workbenchID: workbenchID)
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
        refreshQuestionList(workbenchID: workbenchID)
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
        guard let conversationID = sessions[workbenchID]?.conversationID,
              let question = questionRefs[conversationID], let handoff,
              engine(for: question)?.isBusy != true else {
            beep()
            return
        }
        closeQuestion(workbenchID: workbenchID)
        Task { await handoff.handConversation(question) }
    }

    /// The Questions tab's ⌥⌘↩ on the open conversation.
    func handToClaude(_ question: CodeQuestionRef) {
        guard let handoff, engine(for: question)?.isBusy != true else {
            beep()
            return
        }
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
            questionListErrors[workbenchID] = "Couldn't delete the question: \(error.localizedDescription)"
            return
        }
        forget(question)
        if sessions[workbenchID]?.conversationID == question.conversationID { closeQuestion(workbenchID: workbenchID) }
        if inspectorQuestions[workbenchID] == question.conversationID { inspectorQuestions[workbenchID] = nil }
        questionLists[workbenchID]?.removeAll { $0.conversationID == question.conversationID }
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
    /// off the main actor; nothing for a question asked with no file.
    private func rebuildContextIfNeeded(_ question: CodeQuestionRef) {
        let conversationID = question.conversationID
        guard questionContexts[conversationID] == nil, !question.origin.path.isEmpty else { return }
        if let buffer = workbenches?.codeFiles.existingBuffer(question.project, question.origin.path), buffer.state == .loaded {
            questionContexts[conversationID] = context(origin: question.origin, project: question.project, fileText: buffer.text)
            return
        }
        let file = question.project.folderURL.appendingPathComponent(question.origin.path)
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    return String(bytes: try Data(contentsOf: file), encoding: .utf8)
                } catch {
                    NSLog("CodeQuestionCenter: reading a reopened question's file: %@", error.localizedDescription)
                    return nil
                }
            }.value
            guard let self, let text, questionRefs[conversationID] != nil, questionContexts[conversationID] == nil else { return }
            questionContexts[conversationID] = context(origin: question.origin, project: question.project, fileText: text)
        }
    }
}

private struct WeakChatEngine {
    weak var engine: EmbeddedChatEngine?
}

private struct WeakQuestionPage {
    weak var page: CodeQuestionPage?
}
