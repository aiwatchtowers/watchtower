import CryptoKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Where a review round's line goes (board #328): `SessionLineDelivery` in
/// the app, a recorder in tests.
@MainActor
protocol ReviewLineSink {
    func deliverLine(_ line: String, key: SessionLineDelivery.LineKey, sessionID: Int64) async -> SessionLineDelivery.Delivery
}

extension SessionLineDelivery: ReviewLineSink {
    /// A held line is delivered later by `deliverHeld`; the pane does not follow it.
    func deliverLine(_ line: String, key: LineKey, sessionID: Int64) async -> Delivery {
        await deliverLine(line, key: key, sessionID: sessionID, gate: nil) { _ in }
    }
}

/// The Changes pane's state (board #328, spec §10): one review round of a
/// session — its diff, the task context, the comments (drafts, carried,
/// outdated), the Viewed marks and the guarded Send. Go owns rounds and the
/// send transition; this model reads through `workbench review …` and writes
/// only the Desktop's rows (`ReviewQueries`).
@MainActor
@Observable
final class ReviewChangesModel {
    enum Load: Equatable { case idle, loading, failed(String), ready }
    enum View: Equatable { case all, sinceLastRound }
    enum Mode: String { case quick, deep }
    /// `onRequest`: Quick mode found no cached overview for this tree, so the
    /// strong model runs only when the owner presses Make overview (board #585).
    /// `outdated`: a made overview landed after the tree moved on and none is
    /// cached for the new tree; it is shown as being for an earlier version.
    enum OverviewState: Equatable {
        case idle, loading, onRequest, outdated(ReviewOverview), ready(ReviewOverview), failed(String)
    }

    enum ModelError: Error, Equatable, LocalizedError {
        case noRound
        case fileNotLoaded(String)
        case unknownFile(String)
        case oldSideInSinceView
        case roundNotOpen
        case roundClosed

        var errorDescription: String? {
            switch self {
            case .noRound: "No review round is open."
            case .roundNotOpen: "This round was sent. Refresh to open the next round."
            case .roundClosed: "This round was already sent, so it cannot change."
            case .fileNotLoaded(let path): "The file \(path) is not open, so its lines cannot be anchored."
            case .unknownFile(let path): "The file \(path) is not part of this diff."
            case .oldSideInSinceView: "Switch to All changes to comment on removed lines"
            }
        }
    }

    private(set) var load: Load = .idle
    private(set) var round: ReviewRoundInfo?
    private(set) var files: [ReviewDiffFile] = []
    private(set) var truncated = false
    private(set) var previousTreeLost = false
    private(set) var context: [ReviewContextItem] = []
    private(set) var comments: [ReviewComment] = []
    /// path → the content key it was marked Viewed at.
    private(set) var viewed: [String: String] = [:]
    var selectedPath: String?
    var view: View = .all
    /// The last sides loaded, with the file, tree and view they belong to;
    /// read `currentSides` to show or anchor on them.
    private(set) var sides: LoadedSides?
    private(set) var sending = false
    /// An Undo runs (its CLI call and the refresh after it).
    private(set) var undoing = false
    /// A refresh is running; another one asked for meanwhile runs once after it.
    private(set) var refreshing = false
    private var refreshAgain = false
    /// Whether a refresh asked for while one ran wants a new overview.
    private var refreshAgainRegenerates = false
    private(set) var lastSend: SessionLineDelivery.Delivery?
    /// The last failure of an action after the open (refresh, a file, a comment, Send).
    private(set) var lastError: String?

    // Deep mode (spec §10): persisted through `saveRoundState` on an open round.
    private(set) var mode: Mode = .quick
    private(set) var phase: ReviewPhase = .meaning
    private(set) var chapters: [ReviewChapter] = []
    private(set) var currentChapterKey: String?
    private(set) var lenses: [ReviewLens] = []
    private(set) var lensNotes: [String] = []
    private(set) var checks: [ReviewCheck] = []
    private(set) var pace = ReviewPace(activeSeconds: 0)
    var breakHintDismissed = false
    /// The active seconds the round row holds.
    private var savedActiveSeconds = 0

    // The overview, the agent's notes, undo and answers (Plan 3).
    private(set) var overview: OverviewState = .idle
    /// The overview's load; awaited by tests, replaced when another one starts.
    @ObservationIgnored private(set) var overviewTask: Task<Void, Never>?
    /// The tree the overview shown or loading was asked for; a refresh that
    /// may regenerate asks again when the round's tree differs (after an Undo).
    private var overviewTreeSHA: String?
    /// The model call running (Make overview, Retry or Deep's own): a refresh
    /// or an Undo never cancels it; one landing for an earlier tree is
    /// followed up (board #585).
    @ObservationIgnored private var generationID: UUID?
    /// The failure shown came from the model call, not from a cached read:
    /// Retry repeats whichever failed.
    private var failedGenerating = false
    /// The session's notes and chapters from the agent (`annotate_changes`).
    private(set) var notes: [ReviewNote] = []
    /// Where the selected file's notes sit on its new side; an unplaced note is absent.
    private(set) var notePlacements: [Int64: ReviewCommentAnchor.Placement] = [:]
    /// AI chapters arrived while the owner had checks in the shown chapters: kept until `useAIChapters()`.
    private(set) var aiChaptersPending = false
    private(set) var reverts: [ReviewRevert] = []
    /// Comments the agent answered and resolved (previous and open round), each with Reopen.
    private(set) var agentResolved: [ReviewComment] = []
    /// The AI chapters in use (empty = none chosen yet).
    private var appliedAIChapters: [ReviewChapterSpec] = []
    /// The round's saved `ai:` chapter, waiting for its overview: it stays
    /// the saved position until the AI chapters are back.
    private var awaitedAIChapterKey: String?
    /// The last overview that loaded in this round: its coverage and risk
    /// stay while the next tree's overview loads.
    private var lastReadyOverview: ReviewOverview?
    /// The previous round's agent replies by comment id, for the carried copies.
    private var sourceReplies: [Int64: String] = [:]

    var intentItems: [ReviewIntentItem] {
        guard let ready = lastReadyOverview else { return ReviewWrapUp.intentItems(context) }
        return ReviewWrapUp.intentItems(context, coverage: ready.coverage.map { (index: $0.index, status: $0.status.rawValue) })
    }
    var progress: ReviewProgress {
        ReviewProgress.make(files: files, chapters: chapters) { isViewed($0) }
    }

    /// The base..tree diff: the Viewed keys always come from it, whatever view is shown.
    private var allFiles: [ReviewDiffFile] = []

    private let projectID: Int64
    private let sessionID: Int64
    private let db: DatabasePool
    private let cli: WorkbenchCLI
    private let lineDelivery: any ReviewLineSink
    private let isAgentWorking: @MainActor () -> Bool

    private struct Failure: Error { let message: String }
    private typealias Sides = (old: ReviewFileSide, new: ReviewFileSide)

    /// `isAgentWorking`: the session is working or Agents working
    /// (`agentWorkingKinds`); Undo is off meanwhile (REVIEW-02).
    init(
        projectID: Int64,
        sessionID: Int64,
        cli: WorkbenchCLI,
        db: DatabasePool,
        lineDelivery: any ReviewLineSink,
        isAgentWorking: @escaping @MainActor () -> Bool
    ) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.cli = cli
        self.db = db
        self.lineDelivery = lineDelivery
        self.isAgentWorking = isAgentWorking
    }

    /// The session states in which the agent may still edit the folder.
    static let agentWorkingKinds: Set<SessionSwitcherPresentation.State.Kind> = [.working, .background]
    static let agentWorkingMessage = "The agent is working in this session — undo when it stops."

    /// The pane's reading of `isAgentWorking`: the session's dot state
    /// (a session that is not live does not work, whatever its last hook said).
    static func agentWorks(sessionID: Int64, liveIDs: Set<Int64>, statuses: [Int64: SessionAgentStatus]) -> Bool {
        agentWorkingKinds.contains(SessionSwitcherPresentation.state(of: sessionID, liveIDs: liveIDs, statuses: statuses).kind)
    }

    /// A file's two sides as `review file` returned them for `path` on `treeSHA` in `view`.
    struct LoadedSides: Equatable {
        let path: String
        let treeSHA: String
        let view: View
        let old: ReviewFileSide
        let new: ReviewFileSide
    }

    /// The sides of the selected file on the round's current tree and view;
    /// nil while they load (another file, tree or view picked since).
    var currentSides: LoadedSides? {
        guard let sides, sides.path == selectedPath, sides.treeSHA == round?.treeSha, sides.view == view else { return nil }
        return sides
    }

    var draftCount: Int { comments.filter { $0.status == .draft }.count }

    /// The message when Go answers that the round was already sent.
    static let alreadySentMessage = "This round was already sent"

    /// Whether `path` is marked Viewed at its current content.
    func isViewed(_ path: String) -> Bool {
        guard let file = allFiles.first(where: { $0.path == path }) else { return false }
        return viewed[path] == Self.contentKey(file)
    }

    /// A file's content key: sha256 of its new side's mode and blob id, so a
    /// binary, too-large, truncated or mode-only change moves it too.
    static func contentKey(_ file: ReviewDiffFile) -> String {
        let joined = file.newMode + "\n" + file.newBlob
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Loading

    /// Starts (or resumes) the session's round, then context, diff, comments;
    /// a new round carries the previous round's comments and Viewed marks.
    func open() async {
        guard load != .loading else { return }
        load = .loading
        lastError = nil
        do {
            let start = try Self.checked(await cli.reviewStart(projectID: projectID, sessionID: sessionID, refresh: false))
            guard let info = start.round else { throw Failure(message: "The review round is missing from the answer.") }
            round = info
            previousTreeLost = start.previousTreeLost ?? info.prevTreeLost
            view = info.prevRoundId > 0 && !previousTreeLost ? .sinceLastRound : .all
            let ctx = try Self.checked(await cli.reviewContext(projectID: projectID, sessionID: sessionID))
            context = ctx.items ?? []
            lenses = ctx.lenses ?? []
            lensNotes = ctx.lensNotes ?? []
            mode = Mode(rawValue: info.mode) ?? .quick
            phase = ReviewPhase(stored: info.phase)
            currentChapterKey = info.chapterKey.isEmpty ? nil : info.chapterKey
            pace = ReviewPace(activeSeconds: info.activeSeconds)
            breakHintDismissed = false
            savedActiveSeconds = info.activeSeconds
            overviewTask?.cancel()
            generationID = nil
            overview = .idle
            aiChaptersPending = false
            appliedAIChapters = []
            lastReadyOverview = nil
            awaitedAIChapterKey = info.chapterKey.hasPrefix("ai:") ? info.chapterKey : nil
            try reloadNotes()
            try await loadDiff(info)
            let roundID = info.id
            let rows = try await db.read { try ReviewQueries.comments($0, roundID: roundID) }
            var marks = try await db.read { try ReviewQueries.viewed($0, roundID: roundID) }
            if rows.isEmpty, marks.isEmpty, info.prevRoundId > 0 {
                try await carryOver(from: info.prevRoundId, into: info)
                marks = try await db.read { try ReviewQueries.viewed($0, roundID: roundID) }
            }
            try reloadComments()
            viewed = marks
            checks = try await db.read { try ReviewQueries.checks($0, roundID: roundID) }
            try reloadReverts()
            load = .ready
            noteInteraction()
            startOverview()
            // The next round after a Send keeps the file on screen: its sides come from the new tree.
            if selectedPath != nil { await reloadSides() }
        } catch {
            load = .failed(Self.message(error))
        }
    }

    /// Re-reads the folder's tree: new diff, and this round's drafts and
    /// carried comments re-placed on it (moved, or outdated when lost). One
    /// runs at a time: a call while one runs makes exactly one more run after
    /// it, so the last tree read always wins. A round that is no longer open
    /// gives way to the next one through `open()`, the single path that
    /// creates a round and carries the comments and Viewed marks into it.
    /// `regenerateOverview: false` (an owner Undo) keeps the overview shown
    /// although the tree changed; the next refresh asks again.
    func refresh(regenerateOverview: Bool = true) async {
        guard load == .ready, !sending else { return }
        guard round?.status == "open" else {
            await open()
            return
        }
        guard !refreshing else {
            refreshAgain = true
            refreshAgainRegenerates = refreshAgainRegenerates || regenerateOverview
            return
        }
        refreshing = true
        defer { refreshing = false }
        var regenerate = regenerateOverview
        repeat {
            refreshAgain = false
            refreshAgainRegenerates = false
            await refreshOnce(regenerateOverview: regenerate)
            regenerate = refreshAgainRegenerates
        } while refreshAgain && load == .ready
    }

    private func refreshOnce(regenerateOverview: Bool) async {
        lastError = nil
        do {
            let start = try Self.checked(await cli.reviewStart(projectID: projectID, sessionID: sessionID, refresh: true))
            guard let info = start.round else { throw Failure(message: "The review round is missing from the answer.") }
            let treeChanged = round?.treeSha != info.treeSha
            round = info
            previousTreeLost = start.previousTreeLost ?? info.prevTreeLost
            let ctx = try Self.checked(await cli.reviewContext(projectID: projectID, sessionID: sessionID))
            context = ctx.items ?? []
            lenses = ctx.lenses ?? []
            lensNotes = ctx.lensNotes ?? []
            try reloadNotes()
            try await loadDiff(info)
            // A refresh that may regenerate asks when the overview was built
            // for another tree (also the one an earlier Undo left). After an
            // Undo, without an overview on screen a new one is asked for
            // anyway. A model call still running is left to finish
            // (`startOverview`), and followed up when it lands.
            if regenerateOverview ? overviewTreeSHA != info.treeSha : treeChanged && !overviewShown { startOverview() }
            let roundID = info.id
            let rows = try await db.read { try ReviewQueries.comments($0, roundID: roundID) }
            let stale = rows.filter { ($0.status == .draft || $0.status == .carried) && $0.path != nil && $0.treeSHA != info.treeSha }
            if !stale.isEmpty {
                let plan = try await plan(stale, round: info)
                try await db.write { db in
                    for c in stale {
                        if let place = plan.moved[c.id] {
                            try ReviewQueries.replace(db, id: c.id, placement: place, treeSHA: info.treeSha)
                        } else if plan.lost.contains(c.id) {
                            try ReviewQueries.markOutdated(db, id: c.id)
                        }
                    }
                }
            }
            try reloadComments()
            try reloadReverts()
            await reloadSides()
        } catch {
            lastError = Self.message(error)
        }
    }

    /// The pane's banner was dismissed.
    func clearError() {
        lastError = nil
    }

    func select(_ path: String) async {
        selectedPath = path
        await reloadSides()
    }

    func setView(_ v: View) async {
        guard v != view, let info = round else { return }
        view = v
        lastError = nil
        do {
            try await loadDiff(info)
            await reloadSides()
        } catch {
            lastError = Self.message(error)
        }
    }

    // MARK: - Comments and Viewed

    /// A draft on lines of the open file `path` (anchored by its text on `side`).
    func addComment(path: String, side: String, startLine: Int, endLine: Int, body: String, lens: String = "") throws {
        try run {
            guard let info = round else { throw ModelError.noRound }
            // A sent round is closed: a draft written into it would never be sent.
            guard info.status == "open" else { throw ModelError.roundNotOpen }
            // Old-side lines of the since view belong to the previous tree, not to base.
            guard !(side == "old" && view == .sinceLastRound) else { throw ModelError.oldSideInSinceView }
            guard selectedPath == path, let sides = currentSides else { throw ModelError.fileNotLoaded(path) }
            let text = side == "old" ? sides.old.text : sides.new.text
            let anchor = ReviewCommentAnchor.anchor(text: text, startLine: startLine, endLine: endLine)
            _ = try db.write {
                try ReviewQueries.addDraft($0, roundID: info.id, path: path, side: side, startLine: startLine,
                                           endLine: endLine, anchor: anchor, treeSHA: info.treeSha, body: body, lens: lens)
            }
            try reloadComments()
        }
    }

    func editComment(id: Int64, body: String) throws {
        try run {
            guard let info = round else { throw ModelError.noRound }
            guard info.status == "open" else { throw ModelError.roundNotOpen }
            try db.write { try ReviewQueries.updateDraft($0, id: id, body: body) }
            try reloadComments()
        }
    }

    func deleteComment(id: Int64) throws {
        try run {
            // A carried comment is closed, not deleted: a deleted one would be carried again on reopen.
            let carried = comments.first { $0.id == id }?.status == .carried
            try db.write { carried ? try ReviewQueries.resolve($0, id: id) : try ReviewQueries.deleteDraft($0, id: id) }
            try reloadComments()
        }
    }

    func resolve(id: Int64) throws {
        try run {
            try db.write { try ReviewQueries.resolve($0, id: id) }
            try reloadComments()
        }
    }

    func toggleViewed(_ path: String) throws {
        try run {
            guard let info = round else { throw ModelError.noRound }
            guard let file = allFiles.first(where: { $0.path == path }) else { throw ModelError.unknownFile(path) }
            let key = viewed[path] == Self.contentKey(file) ? nil : Self.contentKey(file)
            try db.write { try ReviewQueries.setViewed($0, roundID: info.id, path: path, contentSHA: key) }
            viewed = try db.read { try ReviewQueries.viewed($0, roundID: info.id) }
        }
    }

    // MARK: - Send

    /// Sends the round once: Go marks the drafts sent, and only the call that
    /// did it types the line. A second call while one runs does nothing; nor
    /// does one during a refresh (the drafts may be re-placed). After it the
    /// round is no longer open here either: no comment is added to it, and
    /// Refresh opens the next round. Go answering "already sent" says so in
    /// `lastError`.
    func send() async {
        guard !sending, !refreshing, !undoing, let info = round else { return }
        sending = true
        defer { sending = false }
        lastError = nil
        flushState()
        do {
            let env = try Self.checked(await cli.reviewSend(projectID: projectID, roundID: info.id))
            // Either way the round is closed now: sent by this call, or already before it.
            round?.status = "sent"
            if env.sent == true {
                if let line = env.line, !line.isEmpty {
                    lastSend = await lineDelivery.deliverLine(line, key: .review(info.id), sessionID: sessionID)
                }
            } else {
                lastError = Self.alreadySentMessage
            }
            try reloadComments()
        } catch {
            lastError = Self.message(error)
        }
    }

    /// Wrap-up marks live under this chapter key and the `intent` lens.
    static let wrapupChapter = "wrapup"
    static let intentLens = "intent"
    /// Unsaved active seconds that trigger a save.
    private static let saveEverySeconds = 30

    // MARK: - Deep

    // Mode, phase, chapter

    func setMode(_ m: Mode) throws {
        try run {
            try saveState(mode: m, phase: phase, chapterKey: persistedChapterKey)
            mode = m
        }
        // Deep makes its overview by itself: switching to it asks for one
        // unless the current tree's is shown (a running model call finishes
        // and is followed up).
        if m == .deep, load == .ready, !(overviewShown && overviewTreeSHA == round?.treeSha) { startOverview() }
    }

    func setPhase(_ p: ReviewPhase) throws {
        try run {
            // A sent round only moves on screen; the position is saved while it is open.
            if round?.status == "open" { try saveState(mode: mode, phase: p, chapterKey: persistedChapterKey) }
            phase = p
        }
    }

    /// Makes `key` the current chapter and opens its first non-collapsed file.
    func selectChapter(_ key: String) async throws {
        guard let chapter = chapters.first(where: { $0.key == key }) else { return }
        try run {
            // A sent round only moves on screen; the position is saved while it is open.
            if round?.status == "open" { try saveState(mode: mode, phase: phase, chapterKey: key) }
            currentChapterKey = key
            awaitedAIChapterKey = nil
        }
        let first = chapter.paths.first { path in files.first { $0.path == path }?.collapsedReason == nil } ?? chapter.paths.first
        if let first { await select(first) }
    }

    /// Chapters from the current view's files (the agent's, else the AI's in
    /// use, else mechanical), and a current chapter that still exists (the
    /// first one otherwise); checks of a vanished chapter stay in the DB.
    private func refreshChapters() {
        chapters = ReviewChapters.resolve(files, agent: agentChapterSpecs, ai: appliedAIChapters)
        if let awaited = awaitedAIChapterKey, chapters.contains(where: { $0.key == awaited }) {
            currentChapterKey = awaited
            awaitedAIChapterKey = nil
            return
        }
        if let key = currentChapterKey, chapters.contains(where: { $0.key == key }) { return }
        currentChapterKey = chapters.first?.key
    }

    // MARK: - Checks and comments

    func checks(forChapter key: String) -> [ReviewCheck] {
        checks.filter { $0.chapterKey == key }
    }

    func setCheck(chapterKey: String, lens: String, itemKey: String, checked: Bool) throws {
        try run {
            let info = try openRound()
            try writeInOpenRound {
                try ReviewQueries.setCheck($0, roundID: info.id, chapterKey: chapterKey, lens: lens, itemKey: itemKey,
                                           state: checked ? .checked : nil)
            }
            try reloadChecks()
        }
    }

    /// A design comment for a checklist question, and the question marked `commented`.
    func commentOnCheck(chapterKey: String, lens: String, item: ReviewLens.Item, body: String) throws {
        try run {
            let info = try openRound()
            try writeInOpenRound { db in
                _ = try Self.addDesign(db, info: info, body: body, lens: lens)
                try ReviewQueries.setCheck(db, roundID: info.id, chapterKey: chapterKey, lens: lens, itemKey: item.key,
                                           state: .commented)
            }
            try reloadComments()
            try reloadChecks()
        }
    }

    func addDesignComment(body: String, lens: String) throws {
        try run {
            let info = try openRound()
            try db.write { _ = try Self.addDesign($0, info: info, body: body, lens: lens) }
            try reloadComments()
        }
    }

    /// Marks a Wrap-up intent item; partial and not done also leave a design comment.
    func markIntent(_ item: ReviewIntentItem, state: ReviewCheck.State, note: String) throws {
        try run {
            let info = try openRound()
            try writeInOpenRound { db in
                // An earlier mark of this item (this round's draft, or a carried one) is replaced.
                let heads = [false, true].map { ReviewWrapUp.intentCommentBody(partial: $0, item: item, note: "") }
                let earlier = try ReviewQueries.comments(db, roundID: info.id).filter { c in
                    c.lens == Self.intentLens && c.path == nil
                        && heads.contains { c.body == $0 || c.body.hasPrefix($0 + " — ") }
                }
                for c in earlier {
                    switch c.status {
                    case .draft: try ReviewQueries.deleteDraft(db, id: c.id)
                    case .carried: try ReviewQueries.resolve(db, id: c.id)
                    default: break
                    }
                }
                if state == .partial || state == .notDone {
                    let body = ReviewWrapUp.intentCommentBody(partial: state == .partial, item: item, note: note)
                    _ = try Self.addDesign(db, info: info, body: body, lens: Self.intentLens)
                }
                try ReviewQueries.setCheck(db, roundID: info.id, chapterKey: Self.wrapupChapter, lens: Self.intentLens,
                                           itemKey: item.key, state: state)
            }
            try reloadComments()
            try reloadChecks()
        }
    }

    // MARK: - Overview and notes

    /// Loads the AI overview of the open round; an answer for another round
    /// is dropped. A failure keeps the chapters as they are. Without
    /// `generate` only a cached overview is read (no model call): a miss
    /// drops the old tree's AI state and leaves Make overview on screen
    /// (`earlier`: the made overview of an earlier tree, shown as such).
    private func loadOverview(generate: Bool, generation: UUID?, earlier: ReviewOverview?) async {
        guard let info = round else { return }
        aiChaptersPending = false
        let state: OverviewState
        do {
            let env = try Self.checked(await cli.reviewOverview(projectID: projectID, roundID: info.id, cachedOnly: !generate))
            if let ready = env.overview {
                state = .ready(ready)
            } else if generate {
                throw Failure(message: "The overview is missing from the answer.")
            } else {
                state = .onRequest
            }
        } catch {
            state = .failed(Self.message(error))
        }
        if let generation, generationID == generation { generationID = nil }
        guard !Task.isCancelled, round?.id == info.id else { return }
        guard round?.treeSha == info.treeSha else {
            // A model call that ran past a tree change is followed up for the
            // new tree: Deep makes its overview; Quick reads its cache and
            // else shows a made one as being for an earlier version.
            guard generate else { return }
            if case .ready(let made) = state {
                startOverview(earlier: made)
            } else {
                startOverview()
            }
            return
        }
        showOverview(state, generated: generate, earlier: earlier)
    }

    private func showOverview(_ state: OverviewState, generated: Bool, earlier: ReviewOverview?) {
        switch state {
        case .ready(let ready):
            overview = state
            lastReadyOverview = ready
            offerAIChapters(ready)
        case .onRequest:
            // No risks, chapters or coverage of code that has changed since.
            lastReadyOverview = nil
            if !appliedAIChapters.isEmpty {
                appliedAIChapters = []
                refreshChapters()
            }
            overview = earlier.map { .outdated($0) } ?? .onRequest
        default:
            failedGenerating = generated
            overview = state
        }
    }

    /// Repeats what failed: a cached read stays a cached read in Quick.
    func retryOverview() {
        startOverview(generate: failedGenerating)
    }

    /// Quick mode's Make overview: one strong-model call for this tree.
    func makeOverview() {
        startOverview(generate: true)
    }

    /// Switches to the AI chapters held back by `aiChaptersPending`.
    func useAIChapters() {
        guard case .ready(let ready) = overview else { return }
        appliedAIChapters = Self.specs(ready)
        aiChaptersPending = false
        refreshChapters()
    }

    private var overviewShown: Bool {
        if case .ready = overview { return true }
        return false
    }

    func risk(for path: String) -> ReviewOverview.Risk? {
        lastReadyOverview?.risk.first { $0.path == path }
    }

    /// Reading time of the shown diff's changed lines (generated and lock files excluded).
    var estimateMinutes: Int {
        ReviewChapters.estimateMinutes(changedLines: progress.totalLines)
    }

    // MARK: - Undo

    var canUndo: Bool {
        round?.status == "open" && !sending && !undoing && !isAgentWorking()
    }

    /// Undoes one hunk of the shown diff in the work tree (Go checks the blob
    /// and `apply --check -R`); refused here while the agent works.
    func undo(hunkID: String) async {
        guard !isAgentWorking() else {
            lastError = Self.agentWorkingMessage
            return
        }
        guard !undoing else { return }
        guard let info = round, info.status == "open", !sending else {
            lastError = ModelError.roundClosed.errorDescription
            return
        }
        undoing = true
        defer { undoing = false }
        lastError = nil
        do {
            _ = try Self.checked(await cli.reviewRevertHunk(projectID: projectID, roundID: info.id, hunkID: hunkID,
                                                            since: view == .sinceLastRound))
            try reloadReverts()
        } catch {
            lastError = Self.message(error)
            return
        }
        await refresh(regenerateOverview: false)
    }

    // MARK: - The agent's answers

    /// The reply shown under a comment: its own, else its source's (a carried copy).
    func agentReply(for comment: ReviewComment) -> String {
        guard comment.agentReply.isEmpty, let source = comment.carriedFrom else { return comment.agentReply }
        return sourceReplies[source] ?? ""
    }

    /// Takes a comment the agent resolved back into the open round.
    func reopen(_ id: Int64) throws {
        try run {
            let info = try openRound()
            try writeInOpenRound { try ReviewQueries.reopen($0, commentID: id, openRoundID: info.id) }
            try reloadComments()
        }
    }

    // MARK: - Active time

    func noteInteraction(at date: Date = .now) {
        pace.noteInteraction(at: date)
    }

    func tick(at date: Date = .now, isKey: Bool) {
        pace.tick(at: date, isKey: isKey)
        if pace.activeSeconds - savedActiveSeconds >= Self.saveEverySeconds { flushState() }
    }

    /// Saves the position and active time now (on disappear and before Send).
    func flushState() {
        guard round?.status == "open" else { return }
        do {
            try saveState(mode: mode, phase: phase, chapterKey: persistedChapterKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func openRound() throws -> ReviewRoundInfo {
        guard let info = round else { throw ModelError.noRound }
        guard info.status == "open" else { throw ModelError.roundClosed }
        return info
    }

    /// A write in the open round: a row that is no longer open rolls the whole
    /// write back and closes the round here, as `saveState` does.
    private func writeInOpenRound(_ body: (Database) throws -> Void) throws {
        do {
            try db.write(body)
        } catch ReviewQueries.ReviewQueryError.roundNotOpen {
            round?.status = "sent"
            throw ModelError.roundClosed
        }
    }

    private func saveState(mode: Mode, phase: ReviewPhase, chapterKey: String?) throws {
        let info = try openRound()
        let seconds = pace.activeSeconds
        let saved = try db.write {
            try ReviewQueries.saveRoundState($0, roundID: info.id, mode: mode.rawValue, phase: phase,
                                             chapterKey: chapterKey ?? "", activeSeconds: seconds)
        }
        guard saved else {
            // The row is no longer open: stop writing to it.
            round?.status = "sent"
            throw ModelError.roundClosed
        }
        savedActiveSeconds = seconds
    }

    private func reloadChecks() throws {
        guard let info = round else { return }
        checks = try db.read { try ReviewQueries.checks($0, roundID: info.id) }
    }

    private static func addDesign(_ db: Database, info: ReviewRoundInfo, body: String, lens: String) throws -> Int64 {
        try ReviewQueries.addDraft(db, roundID: info.id, path: nil, side: "new", startLine: 0, endLine: 0,
                                   anchor: CommentAnchor(quote: "", prefix: "", suffix: "", heading: ""),
                                   treeSHA: info.treeSha, body: body, lens: lens)
    }

    /// Records a failure of a throwing action in `lastError` and rethrows it.
    private func run(_ body: () throws -> Void) throws {
        do {
            lastError = nil
            try body()
        } catch {
            lastError = Self.message(error)
            throw error
        }
    }

    private func reloadComments() throws {
        guard let info = round else { return }
        let (rows, resolved, previous) = try db.read { db in
            (try ReviewQueries.comments(db, roundID: info.id),
             try ReviewQueries.agentResolved(db, previousRoundID: info.prevRoundId, openRoundID: info.id),
             info.prevRoundId > 0 ? try ReviewQueries.comments(db, roundID: info.prevRoundId) : [])
        }
        comments = rows
        agentResolved = resolved
        sourceReplies = previous.reduce(into: [:]) { if !$1.agentReply.isEmpty { $0[$1.id] = $1.agentReply } }
    }

    private func reloadReverts() throws {
        guard let info = round else { return }
        reverts = try db.read { try ReviewQueries.reverts($0, roundID: info.id) }
    }

    private func reloadNotes() throws {
        let (project, session) = (projectID, sessionID)
        notes = try db.read { try ReviewQueries.notes($0, projectID: project, sessionID: session) }
    }

    /// The chapter position to save: a saved `ai:` chapter still waiting for
    /// its overview is kept, not the fallback shown meanwhile.
    private var persistedChapterKey: String? {
        awaitedAIChapterKey ?? currentChapterKey
    }

    private var agentChapterSpecs: [ReviewChapterSpec] {
        notes.filter { $0.kind == .chapter }.map { ReviewChapterSpec(title: $0.text, paths: $0.paths, core: $0.core, lenses: nil) }
    }

    private static func specs(_ overview: ReviewOverview) -> [ReviewChapterSpec] {
        overview.chapters.map { ReviewChapterSpec(title: $0.title, paths: $0.paths, core: $0.core, lenses: $0.lenses) }
    }

    /// Starts the overview's load, dropping a cached read still running but
    /// never a model call (it is followed up when it lands). Deep makes the
    /// overview by itself; Quick only reads a cached one unless the owner
    /// asked (`generate`: Make overview, or Retry of a failed model call).
    private func startOverview(generate: Bool = false, earlier: ReviewOverview? = nil) {
        guard generationID == nil else { return }
        overviewTask?.cancel()
        overviewTreeSHA = round?.treeSha
        let make = generate || mode == .deep
        let generation = make ? UUID() : nil
        generationID = generation
        // The only place that shows the spinner; a cached read keeps what is shown.
        if make { overview = .loading }
        overviewTask = Task { [weak self] in await self?.loadOverview(generate: make, generation: generation, earlier: earlier) }
    }

    /// Switches to the overview's chapters, unless they would replace
    /// chapters the owner already checked in the Chapters phase. AI chapters
    /// the round already used (a saved `ai:` position or checks) come back.
    private func offerAIChapters(_ ready: ReviewOverview) {
        let specs = Self.specs(ready)
        let shown = Set(chapters.map(\.key))
        let candidate = ReviewChapters.resolve(files, agent: agentChapterSpecs, ai: specs)
        let usedAI = awaitedAIChapterKey != nil || checks.contains { $0.chapterKey.hasPrefix("ai:") }
        if !usedAI, candidate != chapters, phase == .chapters, checks.contains(where: { shown.contains($0.chapterKey) }) {
            aiChaptersPending = true
            return
        }
        appliedAIChapters = specs
        refreshChapters()
    }

    /// Places the selected file's notes on its loaded new side.
    private func placeNotes() {
        guard let sides = currentSides else {
            notePlacements = [:]
            return
        }
        let mine = notes.filter { $0.kind == .note && $0.path == sides.path }
        notePlacements = ReviewNotePlacement.place(
            mine.map { (id: $0.id, quote: $0.quote, startLine: $0.startLine, endLine: $0.endLine, treeSHA: $0.treeSHA) },
            currentTree: sides.treeSHA
        ) { _ in sides.new.text }
    }

    private func loadDiff(_ info: ReviewRoundInfo) async throws {
        let since = view == .sinceLastRound
        let all = try await fetchDiff(info, since: false)
        let diff = since ? try await fetchDiff(info, since: true) : all
        guard since == (view == .sinceLastRound) else { return }
        allFiles = all.files
        files = diff.files
        truncated = diff.truncated
        refreshChapters()
        if let selectedPath, !diff.files.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = nil
        }
    }

    private func fetchDiff(_ info: ReviewRoundInfo, since: Bool) async throws -> ReviewDiff {
        let env = try Self.checked(await cli.reviewDiff(projectID: projectID, roundID: info.id, since: since))
        guard let diff = env.diff else { throw Failure(message: "The diff is missing from the answer.") }
        return diff
    }

    /// Loads the sides of the selected file; a stale answer (another file or
    /// view picked meanwhile) is dropped.
    private func reloadSides() async {
        defer { placeNotes() }
        guard let info = round, let path = selectedPath else {
            sides = nil
            return
        }
        let since = view == .sinceLastRound
        let oldPath = files.first { $0.path == path }?.oldPath
        do {
            let loaded = try await fetchSides(path: path, oldPath: oldPath, round: info, since: since)
            guard selectedPath == path, since == (view == .sinceLastRound), round?.treeSha == info.treeSha else { return }
            sides = LoadedSides(path: path, treeSHA: info.treeSha, view: view, old: loaded.old, new: loaded.new)
        } catch {
            guard selectedPath == path else { return }
            sides = nil
            lastError = Self.message(error)
        }
    }

    /// `oldPath`: a renamed file's old path, where its old side is read.
    private func fetchSides(path: String, oldPath: String?, round info: ReviewRoundInfo, since: Bool) async throws -> Sides {
        let env = try Self.checked(await cli.reviewFile(projectID: projectID, roundID: info.id, path: path, oldPath: oldPath,
                                                        since: since))
        guard let old = env.old, let new = env.new else { throw Failure(message: "The file sides are missing from the answer.") }
        return (old, new)
    }

    /// Carries the previous round's sent, carried and outdated comments, and
    /// the Viewed marks whose content key still matches, into the new round;
    /// outdated ones stay outdated, so only sent and carried ones are placed.
    private func carryOver(from previousID: Int64, into info: ReviewRoundInfo) async throws {
        let previous = try await db.read { try ReviewQueries.comments($0, roundID: previousID) }
        let open = previous.filter { $0.status == .sent || $0.status == .carried }
        let plan = try await plan(open, round: info)
        let oldMarks = try await db.read { try ReviewQueries.viewed($0, roundID: previousID) }
        let keys = allFiles.reduce(into: [String: String]()) { $0[$1.path] = Self.contentKey($1) }
        try await db.write { db in
            try ReviewQueries.carry(db, from: previous, into: info.id, plan: plan, treeSHA: info.treeSha)
            for (path, key) in oldMarks where keys[path] == key {
                try ReviewQueries.setViewed(db, roundID: info.id, path: path, contentSHA: key)
            }
        }
    }

    /// Where each line comment lands on the round's current tree.
    private func plan(_ list: [ReviewComment], round info: ReviewRoundInfo) async throws -> ReviewCommentAnchor.Plan {
        var loaded: [String: Sides] = [:]
        for path in Set(list.compactMap(\.path)).sorted() {
            let oldPath = allFiles.first { $0.path == path }?.oldPath
            loaded[path] = try await fetchSides(path: path, oldPath: oldPath, round: info, since: false)
        }
        var result = ReviewCommentAnchor.Plan()
        for side in ["old", "new"] {
            let part = ReviewCommentAnchor.plan(list.filter { $0.side == side }) { path in
                guard let both = loaded[path] else { return nil }
                let s = side == "old" ? both.old : both.new
                return s.exists && !s.binary && !s.tooLarge ? s.text : nil
            }
            result.moved.merge(part.moved) { first, _ in first }
            result.lost.formUnion(part.lost)
        }
        return result
    }

    private static func checked(_ env: ReviewEnvelope) throws -> ReviewEnvelope {
        guard env.ok else { throw Failure(message: env.error ?? "The review command failed.") }
        return env
    }

    private static func message(_ error: Error) -> String {
        (error as? Failure)?.message ?? error.localizedDescription
    }
}
