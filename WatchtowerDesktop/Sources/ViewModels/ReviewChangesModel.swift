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

    enum ModelError: Error, Equatable, LocalizedError {
        case noRound
        case fileNotLoaded(String)
        case unknownFile(String)
        case oldSideInSinceView
        case roundNotOpen

        var errorDescription: String? {
            switch self {
            case .noRound: "No review round is open."
            case .roundNotOpen: "This round was sent. Refresh to open the next round."
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
    /// A refresh is running; another one asked for meanwhile runs once after it.
    private(set) var refreshing = false
    private var refreshAgain = false
    private(set) var lastSend: SessionLineDelivery.Delivery?
    /// The last failure of an action after the open (refresh, a file, a comment, Send).
    private(set) var lastError: String?

    /// The base..tree diff: the Viewed keys always come from it, whatever view is shown.
    private var allFiles: [ReviewDiffFile] = []

    private let projectID: Int64
    private let sessionID: Int64
    private let cli: WorkbenchCLI
    private let db: DatabasePool
    private let lineDelivery: any ReviewLineSink

    private struct Failure: Error { let message: String }
    private typealias Sides = (old: ReviewFileSide, new: ReviewFileSide)

    init(projectID: Int64, sessionID: Int64, cli: WorkbenchCLI, db: DatabasePool, lineDelivery: any ReviewLineSink) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.cli = cli
        self.db = db
        self.lineDelivery = lineDelivery
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
            context = try Self.checked(await cli.reviewContext(projectID: projectID, sessionID: sessionID)).items ?? []
            try await loadDiff(info)
            let roundID = info.id
            var rows = try await db.read { try ReviewQueries.comments($0, roundID: roundID) }
            var marks = try await db.read { try ReviewQueries.viewed($0, roundID: roundID) }
            if rows.isEmpty, marks.isEmpty, info.prevRoundId > 0 {
                try await carryOver(from: info.prevRoundId, into: info)
                rows = try await db.read { try ReviewQueries.comments($0, roundID: roundID) }
                marks = try await db.read { try ReviewQueries.viewed($0, roundID: roundID) }
            }
            comments = rows
            viewed = marks
            load = .ready
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
    func refresh() async {
        guard load == .ready, !sending else { return }
        guard round?.status == "open" else {
            await open()
            return
        }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain && load == .ready
    }

    private func refreshOnce() async {
        lastError = nil
        do {
            let start = try Self.checked(await cli.reviewStart(projectID: projectID, sessionID: sessionID, refresh: true))
            guard let info = start.round else { throw Failure(message: "The review round is missing from the answer.") }
            round = info
            previousTreeLost = start.previousTreeLost ?? info.prevTreeLost
            try await loadDiff(info)
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
    func addComment(path: String, side: String, startLine: Int, endLine: Int, body: String) throws {
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
                                           endLine: endLine, anchor: anchor, treeSHA: info.treeSha, body: body)
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
        guard !sending, !refreshing, let info = round else { return }
        sending = true
        defer { sending = false }
        lastError = nil
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

    // MARK: - Private

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
        comments = try db.read { try ReviewQueries.comments($0, roundID: info.id) }
    }

    private func loadDiff(_ info: ReviewRoundInfo) async throws {
        let since = view == .sinceLastRound
        let all = try await fetchDiff(info, since: false)
        let diff = since ? try await fetchDiff(info, since: true) : all
        guard since == (view == .sinceLastRound) else { return }
        allFiles = all.files
        files = diff.files
        truncated = diff.truncated
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
