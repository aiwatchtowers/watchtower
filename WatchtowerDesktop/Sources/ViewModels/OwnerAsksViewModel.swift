import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The owner asks of the workbench on screen (spec 2026-10-03 Parts 5 and 8).
/// Owned by `WorkbenchesViewModel` (AppState), so the drafts, a pending
/// answer and its notice survive navigation (house rule).
///
/// The agent writes asks from another process (`watchtower mcp --workbench`),
/// which ValueObservation cannot see, so the board's pattern applies: a cheap
/// fingerprint read every 5 s while the Workbench tab is on screen, and on
/// app activation; the asks reload only when it moved.
@MainActor
@Observable
final class OwnerAsksViewModel {
    /// What the last answer to an ask came to, shown beside it.
    enum AnswerNotice: Equatable {
        /// Written; the line went as `sendPrompt` says. An ask without a
        /// session counts as `.noSession`.
        case delivered(TerminalCenter.PromptDelivery)
        /// Not written: the ask was no longer open (withdrawn, superseded).
        case withdrawn

        var text: String {
            switch self {
            case .delivered(.sent): OwnerAsksViewModel.answerTypedNote
            case .delivered(.copied): OwnerAsksViewModel.answerCopiedNote
            case .delivered(.noSession): OwnerAsksViewModel.noSessionNote
            case .withdrawn: OwnerAsksViewModel.withdrawnNote
            }
        }
    }

    /// The session pane's paste and clipboard hints of a comment's Send or a
    /// hand-off (`TerminalCenter.pasteHints`/`clipboardHints`).
    nonisolated static let sentNote = "Pasted into Claude — press Return to send"
    nonisolated static let copiedNote = "Prompt copied — press ⌘V in the terminal"
    /// An answer's line waits for the owner's Return (board #364): the
    /// drawer's notice and the session pane's hint
    /// (`TerminalCenter.answerHints`).
    nonisolated static let answerTypedNote = "Answer typed into the terminal — press Return to send"
    nonisolated static let answerCopiedNote = "Answer copied — paste it into the terminal and press Return"
    nonisolated static let noSessionNote = "Answer saved — it goes to the session's brief when it starts"
    nonisolated static let withdrawnNote = "The agent withdrew this ask — your draft is kept"
    static let pollInterval: Duration = .seconds(5)
    static let drawerWidthKey = "workbench.asks.drawerWidth"
    nonisolated static let drawerWidthRange: ClosedRange<Double> = 320...900
    static let defaultDrawerWidth: Double = 440

    /// One session's closed list, or (`sessionID` nil) the asks filed from
    /// outside the app.
    struct ClosedListKey: Hashable {
        let projectID: Int64
        let sessionID: Int64?
    }

    /// Never written to the DB; answering is what persists a draft.
    let drafts = OwnerAskDrafts()
    /// Review snapshots rendered for the drawer.
    let reviewDocuments = OwnerAskReviewDocuments()
    /// Each workbench's open asks, oldest first, as last read.
    private(set) var openAsks: [Int64: [OwnerAsk]] = [:]
    /// The last answer's outcome per ask id, until dismissed.
    private(set) var answerNotices: [Int64: AnswerNotice] = [:]
    /// Why the last read of a workbench's asks failed; the next read clears it.
    private(set) var loadErrors: [Int64: String] = [:]
    /// Why the last answer to an ask failed, apart from the reads: a good
    /// reload never hides it; the next answer that saves clears it.
    private(set) var answerErrors: [Int64: String] = [:]
    /// Each workbench's closed asks per session (nil = outside the app), as
    /// the session rows count them.
    private(set) var closedCounts: [Int64: [Int64?: Int]] = [:]
    /// Each workbench's superseded ask id → the round that replaced it.
    private(set) var replacements: [Int64: [Int64: Int64]] = [:]
    /// The read-only lists behind "N closed", read when one opens.
    private(set) var closedLists: [ClosedListKey: [OwnerAsk]] = [:]
    private(set) var closedErrors: [ClosedListKey: String] = [:]
    /// The asks a drawer shows that are no longer open (answered, withdrawn
    /// meanwhile, or picked from a closed list), as last read.
    private(set) var shownAsks: [Int64: OwnerAsk] = [:]
    /// Asks an answer is being written for: Answer is disabled meanwhile,
    /// and a second click writes nothing.
    private(set) var answering: Set<Int64> = []
    /// The ask each workbench's drawer shows (nil = closed). An answer that
    /// typed or copied its line closes it: the terminal takes over.
    private(set) var drawerAskIDs: [Int64: Int64] = [:]
    /// Per workbench, the open asks the owner closed a drawer on (Later, ×,
    /// an answer): the drawer does not open on them by itself again — only
    /// a new ask opens it (board #364). Pruned to the open asks on each read.
    private(set) var dismissedAskIDs: [Int64: Set<Int64>] = [:]
    /// The drawer takes the whole session pane; closing it resets this.
    var drawerExpanded = false
    /// The drawer's width, kept across launches under `drawerWidthKey`.
    private(set) var drawerWidth: Double

    /// Whether the Workbench tab is what the owner sees; the poll reads only then.
    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }
    /// The workbench on screen, whose asks the poll follows.
    @ObservationIgnored var watchedProjectID: () -> Int64? = { nil }
    /// An answer's line was typed or copied into `sessionID`: the page shows
    /// that terminal and moves the keyboard into it.
    @ObservationIgnored var onDelivered: ((_ projectID: Int64, _ sessionID: Int64) -> Void)?
    /// A workbench's open asks were read: the page opens a new one's drawer
    /// if its session is on screen (`WorkbenchesViewModel.openNewAsk`).
    @ObservationIgnored var onLoaded: ((_ projectID: Int64) -> Void)?
    /// An answer was saved: the session states re-read their open asks.
    @ObservationIgnored var onAnswered: (() async -> Void)?
    /// Seams for tests: the poll's wait and the activation notifications.
    @ObservationIgnored var pollSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored var notificationCenter: NotificationCenter = .default

    private let dbPool: DatabasePool
    private let terminalCenter: TerminalCenter?
    private let defaults: UserDefaults
    @ObservationIgnored private var fingerprints: [Int64: String] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(dbPool: DatabasePool, terminalCenter: TerminalCenter?, defaults: UserDefaults = .standard) {
        self.dbPool = dbPool
        self.terminalCenter = terminalCenter
        self.defaults = defaults
        drawerWidth = Self.clampDrawerWidth(defaults.object(forKey: Self.drawerWidthKey) as? Double ?? Self.defaultDrawerWidth)
    }

    func stack(projectID: Int64) -> OwnerAskStack {
        OwnerAskStack(openAsks[projectID] ?? [])
    }

    // MARK: - Loading

    /// What one read of a workbench's asks gives.
    private struct Snapshot {
        let open: OwnerAskRows
        let fingerprint: String
        let closedCounts: [Int64?: Int]
        let replacements: [Int64: Int64]
        /// The drawer's ask when it is no longer open.
        let shown: OwnerAsk?
    }

    func load(projectID: Int64) async {
        let drawerID = drawerAskIDs[projectID]
        do {
            let snapshot = try await dbPool.read { db in
                let open = try OwnerAskQueries.openAsks(db, projectID: projectID)
                let shown = try drawerID.flatMap { id in
                    open.asks.contains { $0.id == id } ? nil : try OwnerAskQueries.ask(db, id: id, projectID: projectID)
                }
                return Snapshot(
                    open: open,
                    fingerprint: try Self.fingerprint(db, projectID: projectID),
                    closedCounts: try OwnerAskQueries.closedCounts(db, projectID: projectID),
                    replacements: try OwnerAskQueries.replacements(db, projectID: projectID),
                    shown: shown
                )
            }
            openAsks[projectID] = snapshot.open.asks
            fingerprints[projectID] = snapshot.fingerprint
            closedCounts[projectID] = snapshot.closedCounts
            replacements[projectID] = snapshot.replacements
            if let shown = snapshot.shown { shownAsks[shown.id] = shown }
            dismissedAskIDs[projectID]?.formIntersection(snapshot.open.asks.map(\.id))
            // A row it cannot read is left out of the stack and named here.
            loadErrors[projectID] = snapshot.open.problem
            onLoaded?(projectID)
        } catch {
            // The last list stays beside the error.
            loadErrors[projectID] = "Could not load the asks: \(error.localizedDescription)"
        }
    }

    /// The ask a stack row, a closed list or a notice names: from the open
    /// list, else read (a closed one is kept for the drawer, an open one not
    /// listed yet reloads the list). nil, with the reason in `loadErrors`,
    /// when it is gone or the read failed.
    func lookUp(askID: Int64, projectID: Int64) async -> OwnerAsk? {
        if let ask = openAsks[projectID]?.first(where: { $0.id == askID }) { return ask }
        let found: OwnerAsk?
        do {
            found = try await dbPool.read { try OwnerAskQueries.ask($0, id: askID, projectID: projectID) }
        } catch {
            loadErrors[projectID] = "Could not load the ask: \(error.localizedDescription)"
            return nil
        }
        guard let found else {
            loadErrors[projectID] = "That ask no longer exists."
            return nil
        }
        guard found.isOpen else {
            shownAsks[found.id] = found
            return found
        }
        await load(projectID: projectID)
        return openAsks[projectID]?.first { $0.id == askID } ?? found
    }

    /// The document snapshot of ask `askID` of the workbench, any status
    /// (a review re-round's previous round, for its diff); nil when the ask
    /// is gone.
    func snapshot(askID: Int64, projectID: Int64) async throws -> String? {
        try await dbPool.read { try OwnerAskQueries.ask($0, id: askID, projectID: projectID)?.docSnapshot }
    }

    /// A session's (nil: outside the app) answered, delivered and withdrawn
    /// asks, newest first, for its "N closed" list.
    func loadClosed(projectID: Int64, sessionID: Int64?) async {
        let key = ClosedListKey(projectID: projectID, sessionID: sessionID)
        do {
            // The counts come with the list, so "N closed" matches what it opens.
            let (asks, replaced, counts) = try await dbPool.read { db in
                (try OwnerAskQueries.closedAsks(db, projectID: projectID, sessionID: sessionID),
                 try OwnerAskQueries.replacements(db, projectID: projectID),
                 try OwnerAskQueries.closedCounts(db, projectID: projectID))
            }
            closedLists[key] = asks.asks
            replacements[projectID] = replaced
            closedCounts[projectID] = counts
            closedErrors[key] = asks.problem
        } catch {
            closedErrors[key] = "Could not load the closed asks: \(error.localizedDescription)"
        }
    }

    /// Reloads a workbench's asks when anything about them changed since the
    /// last read — a workbench never read counts as changed. Returns whether
    /// it reloaded.
    @discardableResult
    func refreshIfChanged(projectID: Int64) async -> Bool {
        let current: String
        do {
            current = try await dbPool.read { try Self.fingerprint($0, projectID: projectID) }
        } catch {
            loadErrors[projectID] = "Could not load the asks: \(error.localizedDescription)"
            return false
        }
        guard current != fingerprints[projectID] else { return false }
        await load(projectID: projectID)
        return true
    }

    /// The 5 s poll and app activation, for the whole app run (AppState).
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollSleep(Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.pollTick()
            }
        }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.watchedProjectID() else { return }
                Task { await self.refreshIfChanged(projectID: id) }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// One poll tick: the watched workbench, only while the tab is on screen.
    func pollTick() async {
        guard isTabOnScreen(), let id = watchedProjectID() else { return }
        await refreshIfChanged(projectID: id)
    }

    /// Counts plus the latest stamps of a workbench's asks. Go files and
    /// withdraws asks and marks them delivered in place: the open count, the
    /// max id or a stamp moves with every such write.
    nonisolated private static func fingerprint(_ db: Database, projectID: Int64) throws -> String {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*), MAX(id), SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END),
                       MAX(answered_at), MAX(delivered_at)
                FROM owner_asks WHERE project_id = ?
                """,
            arguments: [projectID]
        ) else { return "" }
        let count: Int = row[0]
        let maxID: Int64? = row[1]
        let open: Int? = row[2]
        let answered: String? = row[3]
        let delivered: String? = row[4]
        return "\(count)|\(maxID ?? 0)|\(open ?? 0)|\(answered ?? "")|\(delivered ?? "")"
    }

    // MARK: - Drawer

    func openDrawer(askID: Int64, projectID: Int64) {
        drawerAskIDs[projectID] = askID
    }

    /// Opens the drawer on `ask`; a closed one shows read-only.
    func openDrawer(_ ask: OwnerAsk) {
        if !ask.isOpen { shownAsks[ask.id] = ask }
        drawerAskIDs[ask.projectID] = ask.id
    }

    /// "Later", the drawer's close and a delivered answer: the drafts stay.
    /// The drawer's session's open asks count as seen — none of them opens
    /// the drawer by itself again (board #364).
    func closeDrawer(projectID: Int64) {
        if let session = drawerAsk(projectID: projectID)?.sessionID {
            let seen = (openAsks[projectID] ?? []).filter { $0.sessionID == session }.map(\.id)
            dismissedAskIDs[projectID, default: []].formUnion(seen)
        }
        hideDrawer(projectID: projectID)
    }

    /// The drawer's session left the screen: the drawer goes, and opens
    /// again by itself when the session comes back with an ask not closed.
    func hideDrawer(projectID: Int64) {
        if let id = drawerAskIDs[projectID] { shownAsks[id] = nil }
        drawerAskIDs[projectID] = nil
        drawerExpanded = false
    }

    /// The ask the workbench's drawer shows: open, or as last read once
    /// it closed (answered, withdrawn meanwhile).
    func drawerAsk(projectID: Int64) -> OwnerAsk? {
        guard let id = drawerAskIDs[projectID] else { return nil }
        return openAsks[projectID]?.first { $0.id == id } ?? shownAsks[id]
    }

    func setDrawerWidth(_ width: Double) {
        drawerWidth = Self.clampDrawerWidth(width)
        defaults.set(drawerWidth, forKey: Self.drawerWidthKey)
    }

    static func clampDrawerWidth(_ width: Double) -> Double {
        min(max(width, drawerWidthRange.lowerBound), drawerWidthRange.upperBound)
    }

    func dismissNotice(askID: Int64) {
        answerNotices[askID] = nil
    }

    // MARK: - Answering

    /// An answer is being written for askID: its draft takes no edits.
    func isAnswering(_ askID: Int64) -> Bool {
        answering.contains(askID)
    }

    /// Every draft edit of the views. Refused while the ask's answer is
    /// being written: the write took the draft as it was, and its success
    /// discards it, so a later edit would be lost.
    @discardableResult
    func editDraft(_ askID: Int64, _ change: (inout OwnerAskDraft) -> Void) -> Bool {
        guard !isAnswering(askID) else { return false }
        drafts.update(askID, change)
        return true
    }

    /// Answers `ask` from its draft (spec 2026-10-03 Part 5, PROJ-12): one
    /// guarded write, and only then exactly one `sendPrompt` of the
    /// `OwnerAskPrompt` line to the ask's session — pasted, never submitted.
    /// An ask without a session, or one not running, gets nothing typed: the
    /// brief delivers it. An ask the agent withdrew meanwhile writes nothing
    /// and keeps the draft. Returns the delivery, nil when nothing was written
    /// (an incomplete draft, an answer already running, a failure).
    /// A review's buttons pass their `verdict`, set on the draft first.
    @discardableResult
    func answer(_ ask: OwnerAsk, verdict: OwnerAskAnswer.Verdict? = nil) async -> TerminalCenter.PromptDelivery? {
        if let verdict { editDraft(ask.id) { $0.verdict = verdict } }
        let draft = drafts.askDraft(for: ask.id)
        guard !isAnswering(ask.id), draft.isAnswerable(for: ask) else { return nil }
        answering.insert(ask.id)
        defer { answering.remove(ask.id) }
        let answer = draft.answer(for: ask)
        let (askID, projectID) = (ask.id, ask.projectID)
        do {
            try await dbPool.write { db in
                try OwnerAskQueries.answer(db, askID: askID, projectID: projectID, with: answer)
            }
        } catch AskAnswerError.notOpen {
            answerNotices[askID] = .withdrawn
            await load(projectID: projectID)
            return nil
        } catch {
            answerErrors[askID] = "Could not save the answer: \(error.localizedDescription)"
            return nil
        }
        answerErrors[askID] = nil
        drafts.discard(askID)
        let line = OwnerAskPrompt.line(id: askID, kind: ask.kind, answer: answer)
        let delivery = ask.sessionID.flatMap { terminalCenter?.sendPrompt(line, sessionID: $0) } ?? .noSession
        answerNotices[askID] = .delivered(delivery)
        if delivery != .noSession, let sessionID = ask.sessionID {
            terminalCenter?.showAnswerHint(delivery, sessionID: sessionID)
            if drawerAskIDs[projectID] == askID { closeDrawer(projectID: projectID) }
            onDelivered?(projectID, sessionID)
        }
        await load(projectID: projectID)
        await onAnswered?()
        return delivery
    }
}
