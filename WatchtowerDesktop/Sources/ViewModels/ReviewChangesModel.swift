import CryptoKit
import Foundation
import GRDB
import Observation
import os
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
    /// `failed`'s `detail` is the provider's own text, shown behind a disclosure.
    enum OverviewState: Equatable {
        case idle, loading, onRequest, outdated(ReviewOverview), ready(ReviewOverview)
        case failed(String, detail: String? = nil)
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
    var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue else { return }
            fullFile = false
            // A line asked for in another file is not this one's.
            if focusRequest?.path != selectedPath { focusRequest = nil }
        }
    }
    /// The diff shows the whole file instead of the changes with unchanged
    /// runs folded (board #959); per file view, never persisted.
    var fullFile = false
    var view: View = .all
    /// Code navigation in the review (board #960): the folder's place in the
    /// repository, nil until the pane read it (no jump lands here till then).
    var pathMap: ReviewPathMap?
    /// A file outside the diff, read-only in the centre area; its path is
    /// relative to the session's code root.
    private(set) var preview: CodeNavLocation?
    /// Bumped per `showLocation` into the preview: the same place asked again
    /// is revealed again.
    private(set) var previewSerial = 0
    /// The preview's cursor, as its page last reported it.
    private var previewCursor: CodeNavLocation?
    /// A line the diff puts on screen once its file is shown (`wt.focus`).
    /// One-shot: cleared once the diff sent it (`focusDelivered`), so a
    /// rebuilt diff view never jumps there again.
    private(set) var focusRequest: FocusRequest?
    private var focusSerial = 0
    /// The line last asked for, per file, for `currentLocation`.
    private var focusedLine: (path: String, line: Int)?
    /// The session's Usages list (`CodeUsagesCenter`) is shown under the
    /// file area: asked from the diff, the preview or the menu while the
    /// pane was key.
    private(set) var showsUsages = false
    /// The file load a `showLocation` started (tests await it).
    @ObservationIgnored private(set) var navigationLoad: Task<Void, Never>?
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
    /// When this model approved the round (#964): the banner's time.
    private(set) var approvedAt: Date?
    /// The round's session was deleted: Approve is off (Go refuses it too).
    private(set) var sessionGone = false
    /// The session's worktree was removed; the open round stayed where it was (board #1012).
    private(set) var placeMissing = false
    /// The round and base (`id:base`) the drafts and carried comments were
    /// last placed on. A row records only its tree, so old-side comments are
    /// re-placed until a placement on the round's base succeeds; a failed one
    /// is retried by the next Refresh.
    @ObservationIgnored private var commentsPlacedOn: String?
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
    /// Every write of the model, one after another (board #670), and the
    /// periodic save under way.
    @ObservationIgnored private let writes = SerialWrites()
    private static let log = Logger(subsystem: Constants.bundleID, category: "review")
    /// How long a write that met a busy database waits before its one retry.
    static let busyRetryDelay: Duration = .milliseconds(300)
    /// Test-only: called before each attempt of a database write with the
    /// attempt's index (0 first, 1 the retry); a throw stands in for the
    /// database's answer.
    @ObservationIgnored var writeHook: ((Int) throws -> Void)?
    @ObservationIgnored private var periodicSave: Task<Void, Never>?
    /// A mode, phase or chapter asked for and not saved yet. A round-state
    /// save writes these when its turn comes, so a save queued earlier
    /// never writes an older value over a newer one of another field.
    @ObservationIgnored private var pendingMode: Mode?
    @ObservationIgnored private var pendingPhase: ReviewPhase?
    @ObservationIgnored private var pendingChapterKey: String?
    /// One pending Viewed toggle per file.
    @ObservationIgnored private let pendingViewed = PendingWrites()

    // The overview, the agent's notes, undo and answers (Plan 3).
    private(set) var overview: OverviewState = .idle
    /// The overview's task (a cached read, or the streamed run's reader);
    /// awaited by tests, replaced when another one starts.
    @ObservationIgnored private(set) var overviewTask: Task<Void, Never>?
    /// The diff (base and tree, `ReviewRoundInfo.diffKey`) the overview shown
    /// or loading was asked for; a refresh that may regenerate asks again when
    /// the round's differs (after an Undo, or a move that changed only the base).
    private var overviewDiffKey: String?
    /// The failure shown came from the model call, not from a cached read:
    /// Retry repeats whichever failed.
    private var failedGenerating = false

    // The map and the streamed overview (board #1025, tech spec §3.5, §3.7, §5).
    /// The round's map: chapters, levels and the file badges come from it.
    private(set) var map: MapState = .loading {
        didSet {
            guard map != oldValue else { return }
            if case .ready(let ready) = map {
                mapFiles = Dictionary(ready.files.map { ($0.path, $0) }) { first, _ in first }
            } else {
                mapFiles = [:]
            }
        }
    }
    /// The map's files by path (a file's danger badge); empty without a map.
    private(set) var mapFiles: [String: ReviewMap.File] = [:]
    /// The diff the map in `map` was built for: until it is the round's, the
    /// chapters are the old map's over the new files and the selection stays.
    @ObservationIgnored private var mapDiffKey: String?
    /// The map's load (on open, Refresh and `retryMap`); awaited by tests.
    @ObservationIgnored private(set) var mapTask: Task<Void, Never>?
    /// Per chapter key, how its description stands; absent = not asked for yet.
    private(set) var chapterStates: [String: ChapterRunState] = [:]
    private(set) var summaryState: ChapterRunState = .pending
    /// The chapters the streamed runs described or failed, by key.
    private(set) var streamedChapters: [String: ReviewStreamChapter] = [:]
    /// Another run holds the branch's lock and this one waits: who (`desktop|agent|cli`, "" unknown).
    private(set) var waitingFor: String?
    /// When the running stream last printed a complete line (any line counts), on `streamClock`.
    var lastStreamLine: Date? { run?.lastLine }
    /// The one overview process of this session (tech spec §3.7).
    @ObservationIgnored private var run: OverviewRun?
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    /// Retries pressed while a run was going: one follow-up run after it.
    @ObservationIgnored private var queuedChapters: [String] = []
    @ObservationIgnored private var summaryQueued = false
    /// The overview that starts once the map is in (none = nothing waits for it).
    @ObservationIgnored private var overviewAfterMap: OverviewStart?
    /// The silence timer's clock; a test swaps it.
    @ObservationIgnored var streamClock: any ReviewStreamClock = SystemReviewStreamClock()

    /// The session's notes and chapters from the agent (`annotate_changes`).
    private(set) var notes: [ReviewNote] = []
    /// Where the selected file's notes sit on its new side; an unplaced note is absent.
    private(set) var notePlacements: [Int64: ReviewCommentAnchor.Placement] = [:]
    private(set) var reverts: [ReviewRevert] = []
    /// Comments the agent answered and resolved (previous and open round), each with Reopen.
    private(set) var agentResolved: [ReviewComment] = []
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

    /// The round's whole diff, whatever view is shown: the branch's size (#712 spec §4.2).
    var wholeDiffFiles: [ReviewDiffFile] { allFiles }

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
    /// A round on the task branch's tip reads commits, not a folder (board #1012).
    static let branchTipUndoMessage = "Undo is not available on a branch review: it reads the branch's commits, not a folder."

    /// The pane's reading of `isAgentWorking`: the session's dot state
    /// (a session that is not live does not work, whatever its last hook said).
    static func agentWorks(sessionID: Int64, liveIDs: Set<Int64>, statuses: [Int64: SessionAgentStatus]) -> Bool {
        agentWorkingKinds.contains(SessionSwitcherPresentation.state(of: sessionID, liveIDs: liveIDs, statuses: statuses).kind)
    }

    /// A file's two sides as `review file` returned them for `path` on `treeSHA` in `view`.
    struct LoadedSides: Equatable {
        let path: String
        let treeSHA: String
        /// The round's `diffKey` (base and tree) they were read for: the old
        /// side is the base's, so a base-only change makes them stale too.
        let diffKey: String
        let view: View
        let old: ReviewFileSide
        let new: ReviewFileSide
    }

    /// The sides of the selected file on the round's current diff and view;
    /// nil while they load (another file, tree, base or view picked since).
    var currentSides: LoadedSides? {
        guard let sides, sides.path == selectedPath, sides.diffKey == round?.diffKey, sides.view == view else { return nil }
        return sides
    }

    var draftCount: Int { comments.filter { $0.status == .draft }.count }

    /// The open comments of earlier rounds still on this round (carried and
    /// outdated): Approve lists them and resolves them only on the owner's
    /// press (REVIEW-03, #964).
    var openEarlierComments: [ReviewComment] {
        comments.filter { $0.status == .carried || $0.status == .outdated }
    }

    /// Why Approve is off, nil when it is on (#964): drafts must be sent or
    /// deleted first, and a round without a session has nobody to finish it.
    var approvalBlocker: String? {
        let drafts = draftCount
        if drafts > 0 {
            return drafts == 1 ? "Send or delete the draft first" : "Send or delete the \(drafts) drafts first"
        }
        return sessionGone ? "The session is gone" : nil
    }

    /// The notice when the session's worktree was removed under an open round (board #1012).
    static let placeMissingMessage = "The session's worktree was removed — this round stays where it was opened"
    /// The message when Go answers that the round was already sent.
    static let alreadySentMessage = "This round was already sent"
    /// Go refused Approve on a round that is still open, with no blocker the
    /// model knows of (the open comments changed under the popover).
    static let approveRefusedMessage = "The round was not approved — check its open comments and approve again"

    /// Whether the round has anything to review — its whole base..tree diff,
    /// whatever view is shown (an empty Since view of a branch with changes
    /// still has them); an empty diff makes no overview.
    var hasChanges: Bool { !allFiles.isEmpty }

    /// The next file after `path` (the first when nil) that is shown and not
    /// Viewed, in list order, wrapping around; nil when no other one is left.
    func nextUnviewed(after path: String?) -> String? {
        unviewed(from: path, step: 1)
    }

    /// The previous such file before `path` (the last when nil), wrapping around.
    func previousUnviewed(before path: String?) -> String? {
        unviewed(from: path, step: -1)
    }

    private func unviewed(from path: String?, step: Int) -> String? {
        let count = files.count
        guard count > 0 else { return nil }
        let start = path.flatMap { p in files.firstIndex { $0.path == p } }
        // Without a start the walk begins just off the list's end it moves away from.
        let origin = start ?? (step > 0 ? -1 : count)
        for offset in 1...count {
            let file = files[((origin + step * offset) % count + count) % count]
            if file.path != path, file.collapsedReason == nil, !isViewed(file.path) { return file.path }
        }
        return nil
    }

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
            // The comments' rows record only their tree: unless this model placed
            // them on the round's base, its old-side comments are re-placed.
            let baseChanged = commentsPlacedOn != Self.placement(info)
            round = info
            placeMissing = start.placeMissing ?? false
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
            resetOverview()
            map = .loading
            try reloadNotes()
            try await loadDiff(info)
            let roundID = info.id
            sessionGone = try await db.read { try ReviewQueries.sessionGone($0, roundID: roundID) }
            approvedAt = nil
            let rows = try await db.read { try ReviewQueries.comments($0, roundID: roundID) }
            var marks = try await db.read { try ReviewQueries.viewed($0, roundID: roundID) }
            if rows.isEmpty, marks.isEmpty, info.prevRoundId > 0 {
                try await carryOver(from: info.prevRoundId, into: info)
                commentsPlacedOn = Self.placement(info)
                marks = try await db.read { try ReviewQueries.viewed($0, roundID: roundID) }
            } else {
                // Go moved the open round to the session's new place (board #1012): its comments follow as on a
                // Refresh. A failure leaves the rows as they were and the round still opens.
                let stale = Self.stale(rows, round: info, baseChanged: baseChanged)
                do {
                    try await replace(stale, round: info)
                    commentsPlacedOn = Self.placement(info)
                } catch {
                    lastError = Self.replaceFailedMessage(count: stale.count, error)
                }
            }
            try reloadComments()
            viewed = marks
            checks = try await db.read { try ReviewQueries.checks($0, roundID: roundID) }
            try reloadReverts()
            load = .ready
            noteInteraction()
            // The overview starts once the map is in: never without one (tech spec §3.5).
            startMap(info, then: .asMode)
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
            let diffChanged = round?.diffKey != info.diffKey
            let baseChanged = commentsPlacedOn != Self.placement(info)
            round = info
            placeMissing = start.placeMissing ?? false
            previousTreeLost = start.previousTreeLost ?? info.prevTreeLost
            // No previous round, or its tree is lost (pruned, or of another
            // place, board #1012): the Since view is gone, as in open().
            if view == .sinceLastRound, info.prevRoundId == 0 || previousTreeLost { view = .all }
            let ctx = try Self.checked(await cli.reviewContext(projectID: projectID, sessionID: sessionID))
            context = ctx.items ?? []
            lenses = ctx.lenses ?? []
            lensNotes = ctx.lensNotes ?? []
            try reloadNotes()
            try await loadDiff(info)
            // A refresh that may regenerate asks when the overview was built
            // for another tree (also the one an earlier Undo left). After an
            // Undo, without an overview on screen a new one is asked for
            // anyway. An empty diff drops whatever overview is shown, Undo or not.
            let wantsOverview = !hasChanges || (regenerateOverview ? overviewDiffKey != info.diffKey : diffChanged && !overviewShown)
            // This session's own run on an earlier snapshot is stopped (its
            // finished chapters stay cached) and started on the new one; a run
            // only waiting for another holder is restarted whatever the refresh.
            // An Undo leaves a describing run to finish; it is followed up when it lands.
            var restart = false
            if let current = run, current.diffKey != info.diffKey, regenerateOverview || current.waiting {
                stopRun()
                restart = true
            }
            startMap(info, then: restart ? .make : wantsOverview ? .asMode : nil)
            let roundID = info.id
            sessionGone = try await db.read { try ReviewQueries.sessionGone($0, roundID: roundID) }
            let rows = try await db.read { try ReviewQueries.comments($0, roundID: roundID) }
            try await replace(Self.stale(rows, round: info, baseChanged: baseChanged), round: info)
            commentsPlacedOn = Self.placement(info)
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
        preview = nil
        await reloadSides()
    }

    // MARK: - Code navigation (board #960)

    /// One ask for a line of a diff file; `serial` makes a repeat fire again.
    struct FocusRequest: Equatable {
        let path: String
        let line: Int
        let serial: Int
    }

    /// A jump's target, relative to the code root: a file of the diff is
    /// selected (read only when it is not the one on screen) and its line
    /// asked for; any other file opens in the read-only preview. false =
    /// the folder's place in the repository is not known yet.
    func showLocation(_ location: CodeNavLocation) -> Bool {
        guard let pathMap else { return false }
        let repoPath = pathMap.toRepo(location.path)
        guard files.contains(where: { $0.path == repoPath }) else {
            preview = location
            previewCursor = nil
            previewSerial += 1
            return true
        }
        preview = nil
        if selectedPath != repoPath {
            selectedPath = repoPath
            navigationLoad = Task { await reloadSides() }
        }
        if location.line > 0 { focusLine(location.line) }
        return true
    }

    /// A line of the selected file into view in the diff (a comment picked
    /// in the list, a jump).
    func focusLine(_ line: Int) {
        guard let path = selectedPath, line > 0 else { return }
        focusSerial += 1
        focusRequest = FocusRequest(path: path, line: line, serial: focusSerial)
        focusedLine = (path, line)
    }

    /// The diff sent request `serial` to its page: it is not sent again.
    func focusDelivered(_ serial: Int) {
        if focusRequest?.serial == serial { focusRequest = nil }
    }

    /// "← Back to diff".
    func closePreview() {
        preview = nil
        previewCursor = nil
    }

    /// The preview page's cursor; a message about another file is stale.
    func previewCursorMoved(_ location: CodeNavLocation) {
        guard location.path == preview?.path else { return }
        previewCursor = location
    }

    /// The root-relative place a diff page message names (`definition`,
    /// `usages`): the page posts from the new side of the file it shows,
    /// by its round path. nil for another file than the selected one (a
    /// stale message) or one outside the workbench folder (no navigation).
    func diffNavigationOrigin(path: String, line: Int, col: Int) -> CodeNavLocation? {
        guard path == selectedPath, let rootPath = pathMap?.toRoot(path) else { return nil }
        return CodeNavLocation(path: rootPath, line: line, col: col)
    }

    func showUsages() {
        showsUsages = true
    }

    func closeUsages() {
        showsUsages = false
    }

    /// Where the review is, root-relative, for Back/Forward: the preview's
    /// cursor, or the selected diff file at the line last asked for (1 when
    /// none). nil without a path map or for a file outside the folder.
    var currentLocation: CodeNavLocation? {
        guard let pathMap else { return nil }
        if let preview { return previewCursor ?? preview }
        guard let selectedPath, let path = pathMap.toRoot(selectedPath) else { return nil }
        let line = focusedLine.flatMap { $0.path == selectedPath ? $0.line : nil } ?? 1
        return CodeNavLocation(path: path, line: line, col: 1)
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
    func addComment(path: String, side: String, startLine: Int, endLine: Int, body: String, lens: String = "") async throws {
        try await run {
            guard let info = round else { throw ModelError.noRound }
            // A sent round is closed: a draft written into it would never be sent.
            guard info.status == "open" else { throw ModelError.roundNotOpen }
            // Old-side lines of the since view belong to the previous tree, not to base.
            guard !(side == "old" && view == .sinceLastRound) else { throw ModelError.oldSideInSinceView }
            guard selectedPath == path, let sides = currentSides else { throw ModelError.fileNotLoaded(path) }
            let text = side == "old" ? sides.old.text : sides.new.text
            let anchor = ReviewCommentAnchor.anchor(text: text, startLine: startLine, endLine: endLine)
            _ = try await write {
                try ReviewQueries.addDraft($0, roundID: info.id, path: path, side: side, startLine: startLine,
                                           endLine: endLine, anchor: anchor, treeSHA: info.treeSha, body: body, lens: lens)
            }
            try reloadComments()
        }
    }

    func editComment(id: Int64, body: String) async throws {
        try await run {
            guard let info = round else { throw ModelError.noRound }
            guard info.status == "open" else { throw ModelError.roundNotOpen }
            try await write { try ReviewQueries.updateDraft($0, id: id, body: body) }
            try reloadComments()
        }
    }

    func deleteComment(id: Int64) async throws {
        try await run {
            // A carried comment is closed, not deleted: a deleted one would be carried again on reopen.
            let carried = comments.first { $0.id == id }?.status == .carried
            try await write { carried ? try ReviewQueries.resolve($0, id: id) : try ReviewQueries.deleteDraft($0, id: id) }
            try reloadComments()
        }
    }

    func resolve(id: Int64) async throws {
        try await run {
            try await write { try ReviewQueries.resolve($0, id: id) }
            try reloadComments()
        }
    }

    /// A second toggle of the file while one waits does nothing (board #670);
    /// the toggle flips the stored mark, read in the same transaction.
    func toggleViewed(_ path: String) async throws {
        try await run {
            guard let info = round else { throw ModelError.noRound }
            guard let file = allFiles.first(where: { $0.path == path }) else { throw ModelError.unknownFile(path) }
            let content = Self.contentKey(file)
            let marks = try await pendingViewed.runThrowing(path) {
                try await self.write { db in
                    let stored = try ReviewQueries.viewed(db, roundID: info.id)[path]
                    try ReviewQueries.setViewed(db, roundID: info.id, path: path, contentSHA: stored == content ? nil : content)
                    return try ReviewQueries.viewed(db, roundID: info.id)
                }
            }
            if let marks { viewed = marks }
        }
    }

    /// Marks (or clears) every path in one write batch; a path the diff does
    /// not know throws before anything is written.
    func setViewed(_ paths: [String], on: Bool) async throws {
        try await run {
            guard let info = round else { throw ModelError.noRound }
            var contents: [String: String] = [:]
            for path in paths {
                guard let file = allFiles.first(where: { $0.path == path }) else { throw ModelError.unknownFile(path) }
                contents[path] = Self.contentKey(file)
            }
            let marks = try await pendingViewed.runThrowing(paths.joined(separator: "\n")) {
                try await self.write { db in
                    for (path, content) in contents {
                        try ReviewQueries.setViewed(db, roundID: info.id, path: path, contentSHA: on ? content : nil)
                    }
                    return try ReviewQueries.viewed(db, roundID: info.id)
                }
            }
            if let marks { viewed = marks }
        }
    }

    /// Marks every file of the chapter Viewed, then moves to the next chapter
    /// that is not done, or to Wrap-up when none is left.
    func markChapterViewed(_ key: String) async throws {
        guard let chapter = chapters.first(where: { $0.key == key }) else { return }
        try await setViewed(chapter.paths.filter { !isViewed($0) }, on: true)
        if let next = nextUndoneChapter(after: key) {
            try await selectChapter(next)
        } else {
            try await setPhase(.wrapup)
        }
    }

    /// A done chapter is un-viewed in full and stays; any other is marked
    /// viewed and the review moves on.
    func toggleChapterViewed(_ key: String) async throws {
        guard let chapter = chapters.first(where: { $0.key == key }) else { return }
        if ReviewChapters.done(chapter, isViewed: { isViewed($0) }) {
            try await setViewed(chapter.paths, on: false)
        } else {
            try await markChapterViewed(key)
        }
    }

    /// The next chapter after `key` that is not done, wrapping past the end;
    /// nil when every other chapter is done.
    func nextUndoneChapter(after key: String) -> String? {
        guard let index = chapters.firstIndex(where: { $0.key == key }) else { return nil }
        let count = chapters.count
        for offset in 1..<max(count, 1) {
            let chapter = chapters[(index + offset) % count]
            if !ReviewChapters.done(chapter, isViewed: { isViewed($0) }) { return chapter.key }
        }
        return nil
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
        await flushState()
        do {
            let env = try Self.checked(await cli.reviewSend(projectID: projectID, roundID: info.id))
            // Either way the round is closed now: sent by this call, or already before it.
            round?.status = "sent"
            if env.sent == true {
                round?.outcome = ReviewOutcome.changes
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

    /// Approves the round once (#964), as `send()` sends it: Go closes the
    /// round as approved first (with `resolveOpen` its carried and outdated
    /// comments resolved in the same transaction), and only the call that did
    /// it types the approved line, through the same `LineKey.review` gate
    /// (REVIEW-04). A refusal types nothing; the round's stored state says
    /// whether it was already closed or is still open (drafts, open comments,
    /// no session), and the message says which.
    func approve(resolveOpen: Bool) async {
        guard !sending, !refreshing, !undoing, let info = round, info.status == "open" else { return }
        sending = true
        defer { sending = false }
        lastError = nil
        await flushState()
        do {
            let env = try Self.checked(await cli.reviewApprove(projectID: projectID, roundID: info.id, resolveOpen: resolveOpen))
            if env.sent == true {
                round?.status = "sent"
                round?.outcome = ReviewOutcome.approved
                approvedAt = Date()
                lastSend = nil
                if let line = env.line, !line.isEmpty {
                    lastSend = await lineDelivery.deliverLine(line, key: .review(info.id), sessionID: sessionID)
                }
                try reloadComments()
            } else {
                try await approveRefused(info.id)
            }
        } catch {
            lastError = Self.message(error)
        }
    }

    /// Go wrote nothing. A round no longer open (or gone) shows closed with
    /// its stored outcome; an open one stays open, its comments and session
    /// re-read, and the blocker that refused it is shown.
    private func approveRefused(_ roundID: Int64) async throws {
        let (state, gone) = try await db.read {
            (try ReviewQueries.roundState($0, roundID: roundID), try ReviewQueries.sessionGone($0, roundID: roundID))
        }
        guard let state, state.status == "open" else {
            round?.status = state?.status ?? "sent"
            round?.outcome = state?.outcome ?? ""
            lastError = Self.alreadySentMessage
            try reloadComments()
            return
        }
        sessionGone = gone
        try reloadComments()
        lastError = approvalBlocker ?? Self.approveRefusedMessage
    }

    /// Wrap-up marks live under this chapter key and the `intent` lens.
    nonisolated static let wrapupChapter = "wrapup"
    nonisolated static let intentLens = "intent"
    /// Unsaved active seconds that trigger a save.
    private static let saveEverySeconds = 30

    // MARK: - Deep

    // Mode, phase, chapter

    func setMode(_ m: Mode) async throws {
        try await run {
            pendingMode = m
            defer { if pendingMode == m { pendingMode = nil } }
            try await saveState()
            mode = m
        }
        // Deep makes its overview by itself: switching to it asks for one
        // unless the current tree's is shown (a running model call finishes
        // and is followed up).
        if m == .deep, load == .ready, !(overviewShown && overviewDiffKey == round?.diffKey) { startOverview() }
    }

    func setPhase(_ p: ReviewPhase) async throws {
        try await run {
            // A sent round only moves on screen; the position is saved while it is open.
            if round?.status == "open" {
                pendingPhase = p
                defer { if pendingPhase == p { pendingPhase = nil } }
                try await saveState()
            }
            phase = p
        }
    }

    /// Makes `key` the current chapter and opens `file`, else its first non-collapsed file.
    func selectChapter(_ key: String, file: String? = nil) async throws {
        guard let chapter = chapters.first(where: { $0.key == key }) else { return }
        try await run {
            // A sent round only moves on screen; the position is saved while it is open.
            if round?.status == "open" {
                pendingChapterKey = key
                defer { if pendingChapterKey == key { pendingChapterKey = nil } }
                try await saveState()
            }
            currentChapterKey = key
        }
        let first = file ?? chapter.paths.first { path in files.first { $0.path == path }?.collapsedReason == nil }
            ?? chapter.paths.first
        if let first { await select(first) }
    }

    /// The map's chapters over the current view's files (a chapter with none
    /// of them is left out), and a current chapter that still exists (the
    /// first one otherwise; a saved `ai:` key of an older release too).
    /// Without a map there are no chapters and the saved position is kept.
    /// Checks of a vanished chapter stay in the DB.
    private func refreshChapters() {
        guard case .ready(let ready) = map else {
            chapters = []
            return
        }
        // Collapsed (generated, lock) files cost no reading time.
        var lines: [String: Int] = [:]
        for file in files where lines[file.path] == nil {
            lines[file.path] = file.collapsedReason == nil ? file.additions + file.deletions : 0
        }
        chapters = ready.chapters.compactMap { chapter in
            let paths = chapter.paths.filter { lines[$0] != nil }
            guard !paths.isEmpty else { return nil }
            return ReviewChapter(
                key: chapter.key, title: chapter.title, paths: paths,
                changedLines: paths.reduce(0) { $0 + (lines[$1] ?? 0) }, core: chapter.core,
                source: chapter.key.hasPrefix("agent:") ? .agent : .mechanical
            )
        }
        if let key = currentChapterKey, chapters.contains(where: { $0.key == key }) { return }
        guard mapDiffKey == round?.diffKey else { return }
        currentChapterKey = chapters.first?.key
    }

    // MARK: - Checks and comments

    func checks(forChapter key: String) -> [ReviewCheck] {
        checks.filter { $0.chapterKey == key }
    }

    func setCheck(chapterKey: String, lens: String, itemKey: String, checked: Bool) async throws {
        try await run {
            let info = try openRound()
            try await writeInOpenRound {
                try ReviewQueries.setCheck($0, roundID: info.id, chapterKey: chapterKey, lens: lens, itemKey: itemKey,
                                           state: checked ? .checked : nil)
            }
            try reloadChecks()
        }
    }

    /// A design comment for a checklist question, and the question marked `commented`.
    func commentOnCheck(chapterKey: String, lens: String, item: ReviewLens.Item, body: String) async throws {
        try await run {
            let info = try openRound()
            try await writeInOpenRound { db in
                _ = try Self.addDesign(db, info: info, body: body, lens: lens)
                try ReviewQueries.setCheck(db, roundID: info.id, chapterKey: chapterKey, lens: lens, itemKey: item.key,
                                           state: .commented)
            }
            try reloadComments()
            try reloadChecks()
        }
    }

    func addDesignComment(body: String, lens: String = "") async throws {
        try await run {
            let info = try openRound()
            try await write { _ = try Self.addDesign($0, info: info, body: body, lens: lens) }
            try reloadComments()
        }
    }

    /// Marks a Wrap-up intent item; partial and not done also leave a design comment.
    func markIntent(_ item: ReviewIntentItem, state: ReviewCheck.State, note: String) async throws {
        try await run {
            let info = try openRound()
            try await writeInOpenRound { db in
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

    // MARK: - Map and overview (board #1025)

    /// The round's map (`review map`, tech spec §3.5): failed = no answer in
    /// `WorkbenchCLI.reviewMapTimeout`, a non-zero exit or unreadable JSON.
    enum MapState: Equatable {
        case loading
        case ready(ReviewMap)
        case failed
    }

    /// No complete line from the overview process for this long: it is stuck
    /// (a slow model call still ticks every 30 s; tech spec §3.2, §3.5).
    static let streamSilenceLimit: TimeInterval = 300
    static let streamSilentMessage = "The overview stopped answering, so it was stopped."
    static let streamEndedMessage = "The overview ended without an answer."
    static let streamUnreadableMessage = "The overview's answer could not be read."

    /// The progress card's line while another run holds the branch (tech spec §5).
    /// A caller Go did not record (a rare race) reads as another run.
    static func waitingText(by caller: String) -> String {
        switch caller {
        case "agent": "The agent is describing this branch — chapters appear as it finishes them"
        case "desktop": "Branch review is describing this branch — chapters appear as it finishes them"
        default: "Another run is describing this branch — chapters appear as it finishes them"
        }
    }

    var waitingText: String? { waitingFor.map(Self.waitingText) }

    /// A chapter's description: the streamed one, else the last overview's.
    func chapterDescription(_ key: String) -> String? {
        streamedChapters[key]?.what ?? lastReadyOverview?.chapters.first { $0.key == key }?.what
    }

    /// Builds the map again after a failure (the banner's Retry); the
    /// overview the failed map held back starts once it is in.
    func retryMap() {
        guard load == .ready, let info = round, hasChanges else { return }
        map = .loading
        refreshChapters()
        mapTask?.cancel()
        mapTask = Task { [weak self] in await self?.loadMap(info) }
    }

    /// Redoes one chapter (`--chapter K`), then the summary. During a run it
    /// is queued: one follow-up run takes every queued key (tech spec §3.7).
    func retry(chapter key: String) {
        guard hasChanges, case .ready = map else { return }
        guard run == nil else {
            if !queuedChapters.contains(key) { queuedChapters.append(key) }
            chapterStates[key] = .queued
            return
        }
        startStream(.chapters([key]))
    }

    /// Redoes the summary from the cached chapters (`--summary`); queued during a run.
    func retrySummary() {
        guard hasChanges, case .ready = map else { return }
        guard run == nil else {
            summaryQueued = true
            summaryState = .queued
            return
        }
        startStream(.summary)
    }

    /// "Describe N remaining": only the chapters the last run did not reach
    /// (`--chapter K` each, then the summary). Failed chapters keep their own
    /// Retry, so the button's count is exactly what runs.
    func describeRemaining() {
        guard hasChanges, case .ready = map, run == nil else { return }
        let keys = describableKeys.filter { chapterStates[$0] == .notStarted }
        guard !keys.isEmpty else { return }
        startStream(.chapters(keys))
    }

    /// Repeats what failed: a cached read stays a cached read in Quick.
    func retryOverview() {
        startOverview(generate: failedGenerating)
    }

    /// Quick mode's Make overview: the streamed run for this tree.
    func makeOverview() {
        startOverview(generate: true)
    }

    private var overviewShown: Bool {
        if case .ready = overview { return true }
        return false
    }

    /// Chapters the overview describes: every chapter but "Can skip".
    var describableKeys: [String] {
        guard case .ready(let ready) = map else { return [] }
        return ready.chapters.filter { !$0.isCollapsed }.map(\.key)
    }

    /// The chapter has no description in this overview (business spec item 4).
    /// After a whole run failed the last ready overview stands, out of date: a
    /// chapter it described shows that text and its risks, not "not described".
    func notDescribed(_ key: String) -> Bool {
        if case .failed = overview, let earlier = lastReadyOverview,
           !earlier.incomplete.contains(key), earlier.chapters.contains(where: { $0.key == key && $0.what != nil }) {
            return false
        }
        return ReviewMapPresentation.notDescribed(chapterStates[key])
    }

    /// The summary's failure line (mockup frame 2c): how many chapters it can be remade from.
    var summaryFailedLine: String {
        let keys = describableKeys
        let described = keys.filter { chapterStates[$0] == .ok || chapterStates[$0] == .cached }.count
        return ReviewMapPresentation.summaryFailedLine(described: described, total: keys.count)
    }

    /// Drops the overview, its states and the run (a new round, an empty diff).
    private func resetOverview() {
        stopRun()
        dropQueue()
        overviewTask?.cancel()
        overview = .idle
        lastReadyOverview = nil
        chapterStates = [:]
        summaryState = .pending
        streamedChapters = [:]
        overviewAfterMap = nil
    }

    /// Which overview waits for the map: the mode's (Deep makes it, Quick
    /// reads the cache) or the model's whatever the mode (Make overview, a
    /// restarted run).
    private enum OverviewStart {
        case asMode, make
    }

    /// Reads the round's map in a task of its own; `then` (nil = nothing new)
    /// starts once it is in. An empty diff has an empty map and no CLI call.
    private func startMap(_ info: ReviewRoundInfo, then start: OverviewStart?) {
        mapTask?.cancel()
        // A run already asked for (Make overview, a restart) is never lowered to the mode's.
        if let start, overviewAfterMap != .make { overviewAfterMap = start }
        guard hasChanges else {
            map = .ready(ReviewMap(chapters: [], files: []))
            mapDiffKey = info.diffKey
            refreshChapters()
            startOverviewAfterMap()
            return
        }
        mapTask = Task { [weak self] in await self?.loadMap(info) }
    }

    private func loadMap(_ info: ReviewRoundInfo) async {
        let next: MapState
        do {
            let env = try Self.checked(await cli.reviewMap(projectID: projectID, roundID: info.id))
            guard let ready = env.map else { throw Failure(message: "The map is missing from the answer.") }
            next = .ready(ready)
        } catch {
            // The class only (FILES-01): Go's text may name files.
            Self.log.error("review map failed: \(error is Failure ? "refused" : "cli", privacy: .public)")
            next = .failed
        }
        guard !Task.isCancelled, round?.id == info.id, round?.diffKey == info.diffKey else { return }
        map = next
        mapDiffKey = info.diffKey
        refreshChapters()
        if case .ready = next {
            startOverviewAfterMap()
        } else if run == nil {
            // A run stopped for this map (a Refresh restart) leaves no spinner or running line behind.
            if overview == .loading { overview = .idle }
            for (key, state) in chapterStates where Self.unsettled(state) { chapterStates[key] = .notStarted }
            if Self.unsettled(summaryState) { summaryState = .notStarted }
        }
    }

    private func startOverviewAfterMap() {
        guard let start = overviewAfterMap else { return }
        overviewAfterMap = nil
        startOverview(generate: start == .make)
    }

    /// Starts the overview of the round's diff, never without a map and never
    /// beside this session's run (it is followed up when it lands). Deep
    /// makes the overview by itself (the streamed run); Quick only reads a
    /// cached one unless the owner asked (`generate`: Make overview, or Retry
    /// of a failed run).
    private func startOverview(generate: Bool = false, earlier: ReviewOverview? = nil) {
        guard hasChanges else {
            // Nothing to summarise: no CLI call of either kind; a run still going is stopped.
            resetOverview()
            overviewDiffKey = round?.diffKey
            return
        }
        guard run == nil, let info = round else { return }
        guard case .ready = map else {
            if generate || overviewAfterMap == nil { overviewAfterMap = generate ? .make : .asMode }
            return
        }
        overviewTask?.cancel()
        adoptOverviewDiff(info.diffKey)
        if generate || mode == .deep {
            startStream(.full)
            return
        }
        overviewTask = Task { [weak self] in await self?.readCachedOverview(info, earlier: earlier) }
    }

    /// The overview is now asked for `key`: what the runs streamed for
    /// another tree goes (only no run is going here, so nothing is queued).
    private func adoptOverviewDiff(_ key: String) {
        if overviewDiffKey != key {
            streamedChapters = [:]
            chapterStates = [:]
            summaryState = .pending
        }
        overviewDiffKey = key
    }

    /// Quick mode's cached read: no model call. A miss drops the old tree's
    /// AI state and leaves Make overview on screen (`earlier`: the made
    /// overview of an earlier tree, shown as such).
    private func readCachedOverview(_ info: ReviewRoundInfo, earlier: ReviewOverview?) async {
        let state: OverviewState
        do {
            let env = try Self.checked(await cli.reviewOverview(projectID: projectID, roundID: info.id, cachedOnly: true))
            state = env.overview.map(OverviewState.ready) ?? .onRequest
        } catch {
            state = .failed(Self.message(error))
        }
        guard !Task.isCancelled, round?.id == info.id, round?.diffKey == info.diffKey else { return }
        showOverview(state, generated: false, earlier: earlier)
    }

    private func showOverview(_ state: OverviewState, generated: Bool, earlier: ReviewOverview?) {
        switch state {
        case .ready(let ready):
            overview = state
            lastReadyOverview = ready
            settleDescribed(ready)
        case .onRequest:
            // No risks or coverage of code that has changed since.
            lastReadyOverview = nil
            chapterStates = [:]
            summaryState = .pending
            streamedChapters = [:]
            overview = earlier.map { .outdated($0) } ?? .onRequest
        default:
            failedGenerating = generated
            overview = state
        }
    }

    /// What a run did not report itself, read from the assembled overview: a
    /// chapter it describes is cached, one in its `incomplete` list (or
    /// without a description) is not started. Queued ones stay queued.
    private func settleDescribed(_ ready: ReviewOverview) {
        let described = Set(ready.chapters.compactMap { $0.what == nil ? nil : $0.key })
        for key in describableKeys where Self.unsettled(chapterStates[key]) {
            chapterStates[key] = described.contains(key) && !ready.incomplete.contains(key) ? .cached : .notStarted
        }
        if Self.unsettled(summaryState) { summaryState = ready.summary.isEmpty ? .notStarted : .cached }
    }

    /// Not yet answered by a run: absent, pending, running or waiting.
    private static func unsettled(_ state: ChapterRunState?) -> Bool {
        switch state {
        case nil, .pending?, .running?, .waiting?: true
        default: false
        }
    }

    // The streamed run (tech spec §3.5, §3.7)

    private enum RunKind: Equatable {
        case full
        case chapters([String])
        case summary
    }

    private struct OverviewRun {
        let id = UUID()
        let roundID: Int64
        let diffKey: String
        let kind: RunKind
        var lastLine: Date
        var waiting = false
        var silenced = false
    }

    private enum RunOutcome {
        case final(ReviewEnvelope)
        case failed(String)
    }

    /// Starts this session's one overview process for `kind`.
    private func startStream(_ kind: RunKind) {
        guard run == nil, let info = round else { return }
        overviewTask?.cancel()
        adoptOverviewDiff(info.diffKey)
        let now = streamClock.now
        let started = OverviewRun(roundID: info.id, diffKey: info.diffKey, kind: kind, lastLine: now)
        run = started
        waitingFor = nil
        markRunning(kind)
        let stream: AsyncThrowingStream<ReviewStreamEvent, Error> = switch kind {
        case .full: cli.reviewOverviewStream(projectID: projectID, roundID: info.id)
        case .chapters(let keys): cli.reviewOverviewStream(projectID: projectID, roundID: info.id, chapters: keys)
        case .summary: cli.reviewOverviewStream(projectID: projectID, roundID: info.id, summaryOnly: true)
        }
        overviewTask = Task { [weak self] in await self?.consume(stream, runID: started.id) }
        watchSilence(started.id)
    }

    private func markRunning(_ kind: RunKind) {
        let keys: [String]
        switch kind {
        case .full:
            // The spinner of the whole overview; a partial run keeps what is shown.
            overview = .loading
            chapterStates = [:]
            streamedChapters = [:]
            keys = describableKeys
        case .chapters(let list):
            keys = list
        case .summary:
            keys = []
        }
        for key in keys { chapterStates[key] = .running }
        summaryState = .running
    }

    /// Stops this session's run, if any: its reader is cancelled, which ends
    /// the stream and terminates the child's process group (finished chapters
    /// are kept: each is cached as it ends). Never signals another process.
    private func stopRun() {
        guard run != nil else { return }
        run = nil
        silenceWatch?.cancel()
        overviewTask?.cancel()
        waitingFor = nil
        dropQueue()
    }

    /// The queued Retries will not run: their lines go back to not started.
    private func dropQueue() {
        queuedChapters = []
        summaryQueued = false
        for (key, state) in chapterStates where state == .queued { chapterStates[key] = .notStarted }
        if summaryState == .queued { summaryState = .notStarted }
    }

    /// The session is gone (deleted): its run is stopped, the map's and the
    /// overview's tasks are cancelled and nothing is followed up.
    func shutDown() {
        overviewAfterMap = nil
        stopRun()
        mapTask?.cancel()
        overviewTask?.cancel()
    }

    private func consume(_ stream: AsyncThrowingStream<ReviewStreamEvent, Error>, runID: UUID) async {
        var outcome: RunOutcome?
        do {
            for try await event in stream {
                guard run?.id == runID else { return }
                let now = streamClock.now
                run?.lastLine = now
                if let end = apply(event) { outcome = end }
            }
        } catch {
            // Ended without its envelope (killed, crashed, cut mid-line) or never started.
            Self.log.error("review overview stream ended without an answer: \(String(describing: type(of: error)), privacy: .public)")
        }
        guard let finished = run, finished.id == runID else { return }
        run = nil
        silenceWatch?.cancel()
        waitingFor = nil
        if finished.silenced { outcome = .failed(Self.streamSilentMessage) }
        land(finished, outcome ?? .failed(Self.streamEndedMessage))
    }

    /// One stream event into the model's state; the run's outcome when it ends it.
    private func apply(_ event: ReviewStreamEvent) -> RunOutcome? {
        switch event {
        case .map(let ready):
            // A run on an earlier snapshot (an Undo lets it finish) never replaces this diff's map.
            if round?.diffKey == run?.diffKey {
                map = .ready(ready)
                mapDiffKey = run?.diffKey
                refreshChapters()
            }
        case .mapFailed:
            if round?.diffKey == run?.diffKey {
                map = .failed
                refreshChapters()
            }
        case .waiting(let caller):
            waitingFor = caller
            run?.waiting = true
            for (key, state) in chapterStates where state == .running { chapterStates[key] = .waiting }
            if summaryState == .running { summaryState = .waiting }
        case .tick:
            break
        case .chapter(let chapter):
            // A part another run cached arrives while waiting; anything else means this run holds the lock.
            if chapter.state != .cached { stopWaiting() }
            streamedChapters[chapter.key] = chapter
            if !queuedChapters.contains(chapter.key) { chapterStates[chapter.key] = chapter.state }
        case let .summary(ok, error):
            stopWaiting()
            if !summaryQueued {
                summaryState = ok ? .ok : .failed(
                    text: error?.text ?? ReviewOverviewStreamDecoder.summaryFailedText, detail: error?.detail
                )
            }
        case .final(let env):
            return .final(env)
        case .finalUnreadable:
            return .failed(Self.streamUnreadableMessage)
        }
        return nil
    }

    private func stopWaiting() {
        guard run?.waiting == true else { return }
        run?.waiting = false
        waitingFor = nil
        for (key, state) in chapterStates where state == .waiting { chapterStates[key] = .running }
        if summaryState == .waiting { summaryState = .running }
    }

    /// A run ended: its outcome is shown on the round and diff it was made
    /// for; one that ran past a diff change is followed up for the new diff
    /// (Deep makes its overview; Quick reads its cache, else shows the made
    /// one as being for an earlier version). Then the queued Retries run.
    private func land(_ finished: OverviewRun, _ outcome: RunOutcome) {
        guard round?.id == finished.roundID else { return }
        guard round?.diffKey == finished.diffKey else {
            dropQueue()
            if case .final(let env) = outcome, env.ok, let made = env.overview {
                startOverview(earlier: made)
            } else {
                startOverview()
            }
            return
        }
        switch outcome {
        case .final(let env) where env.ok:
            if let ready = env.overview {
                showOverview(.ready(ready), generated: true, earlier: nil)
            } else {
                // Go found nothing to describe.
                settleFailed(finished, text: nil, detail: nil)
                if overview == .loading { overview = .idle }
            }
        case .final(let env):
            failRun(finished, text: env.error ?? "The review command failed.", detail: env.detail)
        case .failed(let text):
            failRun(finished, text: text, detail: nil)
        }
        startQueued()
    }

    /// A run that failed as a whole (`busy`, `cancelled`, killed, silent):
    /// the full run's card shows the text with Retry; a partial run's
    /// chapters and summary show it on their own lines.
    private func failRun(_ finished: OverviewRun, text: String, detail: String?) {
        if finished.kind == .full {
            settleFailed(finished, text: nil, detail: nil)
            failedGenerating = true
            overview = .failed(text, detail: detail)
        } else {
            settleFailed(finished, text: text, detail: detail)
        }
    }

    /// The run's chapters and summary it did not answer: failed with `text`,
    /// or not started when there is none.
    private func settleFailed(_ finished: OverviewRun, text: String?, detail: String?) {
        let end: ChapterRunState = text.map { .failed(text: $0, detail: detail) } ?? .notStarted
        for (key, state) in chapterStates where Self.unsettled(state) { chapterStates[key] = end }
        if Self.unsettled(summaryState) { summaryState = end }
    }

    /// The one follow-up run after a run ends: every queued chapter (the
    /// summary is remade after them), else the queued summary.
    private func startQueued() {
        if !queuedChapters.isEmpty {
            let keys = queuedChapters
            queuedChapters = []
            summaryQueued = false
            startStream(.chapters(keys))
        } else if summaryQueued {
            summaryQueued = false
            startStream(.summary)
        }
    }

    /// Fails the run after `streamSilenceLimit` without a complete line; every
    /// line (a tick included) moves the deadline.
    private func watchSilence(_ id: UUID) {
        silenceWatch?.cancel()
        let clock = streamClock
        silenceWatch = Task { [weak self] in
            while let deadline = self?.silenceDeadline(id) {
                if clock.now >= deadline {
                    self?.silence(id)
                    return
                }
                do { try await clock.sleep(until: deadline) } catch { return }
            }
        }
    }

    private func silenceDeadline(_ id: UUID) -> Date? {
        guard let run, run.id == id else { return nil }
        return run.lastLine.addingTimeInterval(Self.streamSilenceLimit)
    }

    private func silence(_ id: UUID) {
        guard run?.id == id else { return }
        Self.log.error("review overview stream silent for \(Int(Self.streamSilenceLimit), privacy: .public) s: stopped")
        run?.silenced = true
        overviewTask?.cancel()
    }

    /// Every risk the AI overview names for a file.
    func risks(for path: String) -> [ReviewOverview.Risk] {
        lastReadyOverview?.risk.filter { $0.path == path } ?? []
    }

    /// The most serious risk of a file (the first of equal levels).
    func highestRisk(for path: String) -> ReviewOverview.Risk? {
        risks(for: path).reduce(nil) { best, next in
            guard let best else { return next }
            return Self.severity(next.level) > Self.severity(best.level) ? next : best
        }
    }

    /// The risks of a chapter's files, most serious first (overview order within a level).
    func chapterRisks(_ key: String) -> [ReviewOverview.Risk] {
        chapterRisks(key, in: lastReadyOverview)
    }

    /// What the chapter's risk section shows (#961): the ready overview's
    /// risks; on a failed refresh the last ready overview's and on an
    /// overview of an earlier version that one's, both out of date. nil = no
    /// overview to show (the section offers to run one). While a run goes, a
    /// chapter it already described shows its streamed risks (board #1025).
    func chapterRiskList(_ key: String) -> (risks: [ReviewOverview.Risk], outOfDate: Bool)? {
        switch overview {
        case .ready: (chapterRisks(key), false)
        case let .outdated(earlier): (chapterRisks(key, in: earlier), true)
        case .failed: lastReadyOverview.map { (chapterRisks(key, in: $0), true) }
        case .loading:
            streamedChapters[key].flatMap { streamed in
                streamed.state == .ok || streamed.state == .cached ? (Self.bySeverity(streamed.risks), false) : nil
            }
        case .idle, .onRequest: nil
        }
    }

    private static func bySeverity(_ risks: [ReviewOverview.Risk]) -> [ReviewOverview.Risk] {
        [ReviewOverview.Risk.Level.high, .medium, .low].flatMap { level in risks.filter { $0.level == level } }
    }

    private func chapterRisks(_ key: String, in overview: ReviewOverview?) -> [ReviewOverview.Risk] {
        guard let chapter = chapters.first(where: { $0.key == key }) else { return [] }
        let paths = Set(chapter.paths)
        return Self.bySeverity((overview?.risk ?? []).filter { paths.contains($0.path) })
    }

    private static func severity(_ level: ReviewOverview.Risk.Level) -> Int {
        switch level {
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }

    /// Reading time of the shown diff's changed lines (generated and lock files excluded).
    var estimateMinutes: Int {
        ReviewChapters.estimateMinutes(changedLines: progress.totalLines)
    }

    // MARK: - Undo

    var canUndo: Bool {
        round?.status == "open" && round?.isBranchTip == false && !sending && !undoing && !isAgentWorking()
    }

    /// Undoes one hunk of the shown diff in the work tree (Go checks the blob
    /// and `apply --check -R`); refused here while the agent works.
    func undo(hunkID: String) async {
        guard round?.isBranchTip != true else {
            lastError = Self.branchTipUndoMessage
            return
        }
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

    /// Takes a comment the agent resolved back into the open round, placed
    /// on the round's current diff: a resolved comment is never re-placed
    /// while resolved, so it may carry anchors from before a move.
    func reopen(_ id: Int64) async throws {
        try await run {
            let info = try openRound()
            try await writeInOpenRound { try ReviewQueries.reopen($0, commentID: id, openRoundID: info.id) }
            let rows = try await db.read { try ReviewQueries.comments($0, roundID: info.id) }
            let reopened = rows.filter {
                ($0.id == id || $0.carriedFrom == id) && ($0.status == .draft || $0.status == .carried) && $0.path != nil
            }
            try await replace(reopened, round: info)
            try reloadComments()
        }
    }

    // MARK: - Active time

    func noteInteraction(at date: Date = .now) {
        pace.noteInteraction(at: date)
    }

    /// - Returns: the periodic save it started, if any.
    @discardableResult
    func tick(at date: Date = .now, isKey: Bool) -> Task<Void, Never>? {
        pace.tick(at: date, isKey: isKey)
        // One periodic save at a time: until it lands the unsaved seconds
        // stay over the mark, and each tick would queue another.
        guard periodicSave == nil, pace.activeSeconds - savedActiveSeconds >= Self.saveEverySeconds else { return nil }
        let save = Task {
            await flushState()
            periodicSave = nil
        }
        periodicSave = save
        return save
    }

    /// Saves the position and active time now (on disappear and before Send).
    func flushState() async {
        guard round?.status == "open" else { return }
        do {
            try await saveState()
        } catch {
            // A background save: the next flush writes it again, nothing to show.
            Self.log.error("review state save failed: \(error.localizedDescription, privacy: .public)")
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
    private func writeInOpenRound(_ body: @escaping @Sendable (Database) throws -> Void) async throws {
        do {
            try await write(body)
        } catch ReviewQueries.ReviewQueryError.roundNotOpen {
            round?.status = "sent"
            throw ModelError.roundClosed
        }
    }

    /// A database write in the model's chain (board #670): it starts only
    /// once every write asked for before it finished.
    private func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.retryingBusy { try await self.db.write(body) } }
    }

    /// Runs one database write, and once more after `busyRetryDelay` when
    /// the database answered busy; a second busy throws.
    private func retryingBusy<T>(_ attempt: () async throws -> T) async throws -> T {
        do {
            try writeHook?(0)
            return try await attempt()
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
            try await Task.sleep(for: Self.busyRetryDelay)
            try writeHook?(1)
            return try await attempt()
        }
    }

    /// Saves the round state in the chain. What it writes is read when its
    /// turn comes: the pending mode, phase and chapter over the shown ones.
    private func saveState() async throws {
        try await writes.runThrowing { try await self.writeState() }
    }

    private func writeState() async throws {
        let info = try openRound()
        let mode = pendingMode ?? self.mode
        let phase = pendingPhase ?? self.phase
        let chapterKey = pendingChapterKey ?? currentChapterKey
        let seconds = pace.activeSeconds
        let saved = try await retryingBusy {
            try await db.write {
                try ReviewQueries.saveRoundState($0, roundID: info.id, mode: mode.rawValue, phase: phase,
                                                 chapterKey: chapterKey ?? "", activeSeconds: seconds)
            }
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

    nonisolated private static func addDesign(_ db: Database, info: ReviewRoundInfo, body: String, lens: String) throws -> Int64 {
        try ReviewQueries.addDraft(db, roundID: info.id, path: nil, side: "new", startLine: 0, endLine: 0,
                                   anchor: CommentAnchor(quote: "", prefix: "", suffix: "", heading: ""),
                                   treeSHA: info.treeSha, body: body, lens: lens)
    }

    /// Records a failure of a throwing action in `lastError` and rethrows it.
    private func run(_ body: () async throws -> Void) async throws {
        do {
            lastError = nil
            try await body()
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
            guard selectedPath == path, since == (view == .sinceLastRound), round?.diffKey == info.diffKey else { return }
            sides = LoadedSides(path: path, treeSHA: info.treeSha, diffKey: info.diffKey, view: view, old: loaded.old, new: loaded.new)
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
        try await write { db in
            try ReviewQueries.carry(db, from: previous, into: info.id, plan: plan, treeSHA: info.treeSha)
            for (path, key) in oldMarks where keys[path] == key {
                try ReviewQueries.setViewed(db, roundID: info.id, path: path, contentSHA: key)
            }
        }
    }

    /// The round's drafts and carried comments placed on another diff: made
    /// on another tree, or on the old side when the base may have changed
    /// (a row records only its tree).
    private static func stale(_ rows: [ReviewComment], round info: ReviewRoundInfo, baseChanged: Bool) -> [ReviewComment] {
        rows.filter {
            ($0.status == .draft || $0.status == .carried) && $0.path != nil
                && ($0.treeSHA != info.treeSha || (baseChanged && $0.side == "old"))
        }
    }

    /// The number of lines in text (a final newline ends the last line; an
    /// empty text has none).
    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? parts - 1 : parts
    }

    /// The `commentsPlacedOn` key of a round.
    private static func placement(_ info: ReviewRoundInfo) -> String { "\(info.id):\(info.baseSha)" }

    /// The banner when `open()` could not re-place a moved round's comments.
    static func replaceFailedMessage(count: Int, _ error: Error) -> String {
        "Could not re-place \(count) \(count == 1 ? "comment" : "comments") on the new tree: \(message(error))"
    }

    /// Re-places stale comments onto the round's current diff: moved, or
    /// outdated when their lines are lost.
    private func replace(_ stale: [ReviewComment], round info: ReviewRoundInfo) async throws {
        guard !stale.isEmpty else { return }
        let plan = try await plan(stale, round: info)
        try await write { db in
            for c in stale {
                if let place = plan.moved[c.id] {
                    try ReviewQueries.replace(db, id: c.id, placement: place, treeSHA: info.treeSha)
                } else if plan.lost.contains(c.id) {
                    try ReviewQueries.markOutdated(db, id: c.id)
                }
            }
        }
    }

    /// Where each line comment lands on the round's current tree. A comment
    /// on blank lines has no quote to look for: it is outdated when its side
    /// of the file is gone or no longer reaches its lines, else left where it is.
    private func plan(_ list: [ReviewComment], round info: ReviewRoundInfo) async throws -> ReviewCommentAnchor.Plan {
        var loaded: [String: Sides] = [:]
        for path in Set(list.compactMap(\.path)).sorted() {
            let oldPath = allFiles.first { $0.path == path }?.oldPath
            loaded[path] = try await fetchSides(path: path, oldPath: oldPath, round: info, since: false)
        }
        var result = ReviewCommentAnchor.Plan()
        for side in ["old", "new"] {
            let text = { (path: String) -> String? in
                guard let both = loaded[path] else { return nil }
                let s = side == "old" ? both.old : both.new
                return s.exists && !s.binary && !s.tooLarge ? s.text : nil
            }
            let onSide = list.filter { $0.side == side }
            // A design comment (no path) is left to ReviewCommentAnchor.plan, which leaves it alone.
            let blank = onSide.filter { $0.path != nil && $0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for c in blank where !(c.path.flatMap(text).map { Self.lineCount($0) >= c.endLine } ?? false) {
                result.lost.insert(c.id)
            }
            let part = ReviewCommentAnchor.plan(onSide.filter { !blank.contains($0) }, textFor: text)
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

/// The streamed overview's silence timer reads and waits on this clock (a
/// test drives a fake one).
protocol ReviewStreamClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws
}

/// Time the Mac is asleep does not count: the child is suspended too and its
/// 30 s tick runs on a clock that stops in sleep, so a lid closed mid-run
/// never reads as silence on wake.
struct SystemReviewStreamClock: ReviewStreamClock {
    var now: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

    func sleep(until deadline: Date) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now))), clock: .suspending)
    }
}
