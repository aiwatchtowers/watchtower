import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Drives the Ideas & Decisions registry: a review queue (freshly proposed or
/// explicitly flagged ideas) plus a filterable browsable registry of everything
/// else. See `internal/db/ideas.go` on the Go side and `IdeaQueries` for the
/// underlying reads/writes. Structure mirrors `TargetsViewModel`.
@MainActor
@Observable
final class IdeasViewModel {
    var reviewItems: [Idea] = []
    var registryItems: [Idea] = []
    var isLoading = false
    var errorMessage: String?

    /// State for the "Find ideas" backfill sheet. Lives here rather than on
    /// the sheet's own @State — the house async-op rule — so a run started
    /// from the sheet keeps going (and its result is still there) if the
    /// sheet is dismissed and reopened, or the user switches tabs and back.
    var isBackfilling = false
    var backfillSummary: String?
    var backfillError: String?
    /// SB7: moved off the sheet's own @State so the elapsed-timer display
    /// survives dismiss/reopen too, not just isBackfilling/backfillSummary.
    var backfillStartedAt: Date?
    /// The last requested mining window — seeds the sheet's date state on
    /// reopen, so a sheet opened mid-run (or right after one) shows the range
    /// that is actually mining instead of re-initialised defaults.
    var backfillFrom: Date?
    var backfillTo: Date?

    /// Master-detail selection. Lives here — the VM is AppState-owned — so
    /// selection survives tab/sidebar navigation.
    var selectedID: Int?

    /// The Ideas | Notes segment. Lives here (the VM is AppState-owned) so the
    /// chosen segment survives tab/sidebar navigation. Scopes BOTH lists — the
    /// review queue included, so a flagged note is reviewed under Notes.
    var kindMode: String = "idea"

    /// Ideas + notes across BOTH segments: what the full-screen empty state
    /// keys off, so an empty Notes segment doesn't take the segmented control
    /// off screen while ideas exist.
    var totalCount = 0

    /// Review-queue size per kind — the segment labels' counts, so a queue
    /// waiting in the other segment is visible without switching to it.
    var reviewCounts: [String: Int] = [:]

    /// Cap on the registry browse query; the review queue is unbounded (it's
    /// meant to stay small by daily triage).
    private let registryLimit = 200

    private let dbManager: DatabaseManager
    /// The presses through the tower and each idea row's state.
    let presses: TowerPresses
    /// One pending create or conversion (board #670).
    let pendingWrites = PendingWrites()
    /// SB4: retained so cancelBackfill() has something to cancel — started
    /// and cleared by startBackfillTask, the sheet's Start-button entry point.
    private var backfillTask: Task<Void, Never>?

    /// Overrides CLI resolution for tests; production falls back to
    /// `ProcessCLIRunner.makeDefault()` (mirrors `TargetsViewModel`).
    private let cliRunner: CLIRunnerProtocol?

    /// SB1: pinned to UTC so the `--from`/`--to` calendar day the CLI parses
    /// matches what the owner picked, regardless of the machine's local time
    /// zone (the house dual-path rule — a date-only field must not silently
    /// roll to the adjacent day near midnight).
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    var selectedItem: Idea? {
        guard let id = selectedID else { return nil }
        return reviewItems.first { $0.id == id } ?? registryItems.first { $0.id == id }
    }

    init(dbManager: DatabaseManager, cliRunner: CLIRunnerProtocol? = nil, tower: (any TowerSending)? = nil) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
        presses = TowerPresses(tower: tower)
        presses.reread = { [weak self] in self?.load() }
    }

    func select(_ id: Int?) {
        selectedID = id
    }

    func load() {
        isLoading = true
        let query = currentQuery()
        apply(Result { try dbManager.dbPool.read { try Self.read($0, query) } })
        isLoading = false
    }

    private struct Query {
        let kind: String
        let limit: Int
    }

    private struct Loaded {
        let review: [Idea]
        let registry: [Idea]
        let total: Int
        let counts: [String: Int]
    }

    private func currentQuery() -> Query {
        Query(kind: kindMode, limit: registryLimit)
    }

    nonisolated private static func read(_ db: Database, _ query: Query) throws -> Loaded {
        Loaded(
            review: try IdeaQueries.fetchForReview(db, kind: query.kind),
            registry: try IdeaQueries.fetchList(
                db,
                kind: query.kind,
                limit: query.limit,
                excludingReviewQueue: true
            ),
            total: try IdeaQueries.countIdeasAndNotes(db),
            counts: try IdeaQueries.reviewCountsByKind(db)
        )
    }

    private func apply(_ result: Result<Loaded, Error>) {
        switch result {
        case let .success(loaded):
            reviewItems = loaded.review
            registryItems = loaded.registry
            totalCount = loaded.total
            reviewCounts = loaded.counts
            errorMessage = nil
            reconcileSelection()
        case let .failure(error):
            reviewItems = []
            registryItems = []
            totalCount = 0
            reviewCounts = [:]
            selectedID = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps the selection valid across reloads: an id still present (in either
    /// list) is kept; a vanished or absent selection falls back to the first
    /// review item, then the first registry item, then nil.
    private func reconcileSelection() {
        if let id = selectedID, reviewItems.contains(where: { $0.id == id }) || registryItems.contains(where: { $0.id == id }) {
            return
        }
        selectedID = reviewItems.first?.id ?? registryItems.first?.id
    }

    // MARK: - Actions

    // Every write is an `ideas.*` tower command (#1170 Task 12): Go writes
    // the row, and the idea's row carries the press's state (`presses`).
    // The verdicts return whether the write landed: the Inbox's row actions
    // keep a failure on the row (`pressFailure`).

    /// The row key of `idea`'s presses.
    static func row(_ id: Int) -> String { "idea:\(id)" }

    @discardableResult
    func approve(_ idea: Idea) async -> Bool {
        await setStatus(idea, "active", label: TowerPressText.approving)
    }

    @discardableResult
    func reject(_ idea: Idea) async -> Bool {
        await setStatus(idea, "rejected", label: TowerPressText.rejecting)
    }

    @discardableResult
    func activate(_ idea: Idea) async -> Bool {
        await setStatus(idea, "active", label: TowerPressText.updating)
    }

    @discardableResult
    func notNow(_ idea: Idea, until: String = "") async -> Bool {
        let until: String? = until.isEmpty ? nil : until
        return await press(.ideasSnooze, idea.id, label: TowerPressText.snoozing, variant: until ?? "") {
            IdeaSnoozeRequest(requestID: $0, id: Int64(idea.id), until: until)
        }
    }

    @discardableResult
    func drop(_ idea: Idea) async -> Bool {
        await setStatus(idea, "dropped", label: TowerPressText.updating)
    }

    func merge(_ idea: Idea, into targetID: Int) async {
        await press(.ideasMerge, idea.id, label: TowerPressText.updating, variant: "\(targetID)") {
            IdeaMergeRequest(requestID: $0, id: Int64(idea.id), into: Int64(targetID))
        }
    }

    /// A decision's Supersede (no replacing idea named).
    func supersede(_ idea: Idea) async {
        await press(.ideasSupersede, idea.id, label: TowerPressText.updating) {
            IdeaSupersedeRequest(requestID: $0, id: Int64(idea.id), by: nil)
        }
    }

    /// A decision's Reverse.
    func reverse(_ idea: Idea) async {
        await setStatus(idea, "reversed", label: TowerPressText.updating)
    }

    /// Hard delete — the row, its mentions, and its Discuss chat (Go's
    /// `ideas.delete`). The reload's `reconcileSelection()` moves the
    /// selection off the vanished id.
    @discardableResult
    func deleteIdea(_ idea: Idea) async -> Bool {
        await press(.ideasDelete, idea.id, label: TowerPressText.deleting) {
            ScreenIDRequest(requestID: $0, id: Int64(idea.id))
        }
    }

    /// Returns whether the rating landed, so the view can keep the owner's
    /// typed comment on screen when it did not (clear-only-on-success).
    @discardableResult
    func setRating(_ idea: Idea, rating: Int, comment: String = "") async -> Bool {
        await press(.ideasRating, idea.id, label: TowerPressText.saving, variant: "\(rating)|\(comment)") {
            IdeaRatingRequest(requestID: $0, id: Int64(idea.id), rating: rating, comment: comment)
        }
    }

    /// The failure `idea`'s last press left on its row, nil when it landed.
    func pressFailure(_ idea: Idea) -> String? {
        switch presses.state(Self.row(idea.id)) {
        case .refused(let sentence): sentence
        case .unknown: TowerText.didntConfirmMac
        case .busy, nil: nil
        }
    }

    /// A create (`ideas.create`). Creates share one row (`createRow`): one
    /// made while another waits goes after it, so no new idea is dropped;
    /// only the same idea pressed again while its create waits does nothing
    /// (nil, board #670) — a double press, not a second idea.
    @discardableResult
    func createManual(kind: String, title: String, essence: String) async -> Int? {
        let created = await pendingWrites.run("create|\(kind)|\(title)|\(essence)") {
            await insertManual(kind: kind, title: title, essence: essence)
        }
        return created.flatMap { $0 }
    }

    /// The row key of a create.
    static let createRow = "idea:new"

    private func insertManual(kind: String, title: String, essence: String) async -> Int? {
        let created: CreatedResult? = await presses.send(
            .ideasCreate, row: Self.createRow, label: TowerPressText.saving, variant: "\(kind)|\(title)|\(essence)"
        ) { IdeaCreateRequest(requestID: $0, kind: kind, title: title, essence: essence) }
        guard let created else {
            errorMessage = pressFailure(row: Self.createRow).map { "Failed to create idea: \($0)" }
            return nil
        }
        // Show what was just created: switch to its segment and select it. The Decisions ledger creates through this same VM
        // and has no segment here, so a decision leaves the tab as it was.
        if kind == "idea" || kind == "note" {
            kindMode = kind
            selectedID = Int(created.id)
        }
        load()
        return Int(created.id)
    }

    /// Converts an idea into a Target (`ideas.converted`): Go creates the
    /// target from the idea's title/essence (`source_type: "idea"`) and marks
    /// the idea converted with a link back to it in one write, and returns
    /// the new target id so the caller can navigate via
    /// `AppState.navigateToTarget`. One conversion per idea at a time: a
    /// second press while the first waits does nothing (nil), and a second
    /// conversion of a converted idea answers its target, so no second
    /// target is made.
    @discardableResult
    func convertToTarget(_ idea: Idea) async -> Int? {
        let converted = await pendingWrites.run("convert:\(idea.id)") { await convert(idea) }
        return converted.flatMap { $0 }
    }

    private func convert(_ idea: Idea) async -> Int? {
        let today = Self.dateFormatter.string(from: Date())
        let result: IdeaConvertResult? = await presses.send(
            .ideasConverted, row: Self.row(idea.id), label: TowerPressText.converting
        ) { IdeaConvertedRequest(requestID: $0, id: Int64(idea.id), today: today) }
        return result.map { Int($0.targetID) }
    }

    private func setStatus(_ idea: Idea, _ status: String, label: String) async -> Bool {
        await press(.ideasStatus, idea.id, label: label, variant: status) {
            IdeaStatusRequest(requestID: $0, id: Int64(idea.id), status: status)
        }
    }

    /// One press on idea `id`'s row; whether it landed.
    @discardableResult
    private func press<Params: Encodable & Sendable>(
        _ command: TowerCommand,
        _ id: Int,
        label: String,
        variant: String = "",
        _ params: @escaping (String) -> Params
    ) async -> Bool {
        let result: ActResult? = await presses.send(command, row: Self.row(id), label: label, variant: variant,
                                                    params: params)
        return result != nil
    }

    private func pressFailure(row: String) -> String? {
        if case .refused(let sentence) = presses.state(row) { return sentence }
        return nil
    }

    // MARK: - Find-ideas backfill

    /// SB4: the sheet's Start button's entry point — creates and retains the
    /// backfill Task on the VM (rather than the view firing an unstructured
    /// `Task { await vm.startBackfill(...) }` itself) so cancelBackfill() has
    /// something to cancel. Guarded before creating the Task too, so a stray
    /// second call while a run is in flight can't replace the retained
    /// reference to the run actually still going (startBackfill's own
    /// synchronous guard already covers the race between the two guards).
    func startBackfillTask(from: Date, to: Date) {
        guard !isBackfilling else { return }
        backfillFrom = from
        backfillTo = to
        backfillTask = Task { [weak self] in
            await self?.startBackfill(from: from, to: to)
            self?.backfillTask = nil
        }
    }

    /// Cancels the in-flight backfill Task. ProcessCLIRunner's cancellation
    /// handler sends SIGTERM to the CLI child on cancellation, which the Go
    /// wave's GB8 now catches as a real interrupt (releasing the backfill
    /// lock and restoring floors) instead of leaving an orphaned process —
    /// see the CancellationError branch below.
    func cancelBackfill() {
        backfillTask?.cancel()
    }

    /// Runs `watchtower ideas mine --from --to` over a historical window (the
    /// Settings/sheet-driven backfill — separate from the daemon's regular
    /// mining pass). Guarded synchronously against double-start: the check and
    /// the `isBackfilling = true` flip both happen before the first `await`,
    /// so a second call made while the first is in flight can't race past it.
    /// Errors do not clear a prior success's `backfillSummary` — only a new
    /// success replaces it (clear-only-on-success).
    func startBackfill(from: Date, to: Date) async {
        guard !isBackfilling else { return }
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            backfillError = "watchtower CLI not found in PATH"
            return
        }
        isBackfilling = true
        backfillStartedAt = Date()
        backfillError = nil
        let args = [
            "ideas", "mine",
            "--from", Self.dateFormatter.string(from: from),
            "--to", Self.dateFormatter.string(from: to)
        ]
        // SB6: load() runs on every terminal path below, not just success —
        // a nonzero exit or a malformed final envelope can still follow a
        // run that already committed ideas to the DB, and those must not
        // stay invisible until some unrelated reload.
        do {
            let data = try await runner.run(args: args)
            isBackfilling = false
            backfillStartedAt = nil
            if Task.isCancelled {
                // Cancellation is authoritative and checked BEFORE any
                // envelope parsing: a cancel can race the CLI's own
                // completion, so `runner.run` may still hand back
                // perfectly valid data (or throw nothing at all) around the
                // same moment Cancel is pressed. That must still read as
                // "Cancelled", never as a parsed (or parse-failed) result —
                // matches the CancellationError branch in `catch` below,
                // which only covers the case where run() actually threw.
                backfillError = "Cancelled"
                load()
                return
            }
            if Self.parseDisabledEnvelope(data)?.disabled == true {
                // GB9 (Go wave): ideas.enabled=false on the backfill path
                // emits {"disabled":true} instead of the usual envelope —
                // that must read as an actionable message, not an opaque
                // parse failure.
                backfillError = "The ideas registry is disabled in Settings."
                load()
                return
            }
            guard let envelope = Self.parseBackfillEnvelope(data) else {
                backfillError = "Could not parse the backfill result."
                load()
                return
            }
            backfillSummary = "Proposed \(envelope.proposed) ideas (\(envelope.cycles) cycles, \(envelope.mentionsDeduped) duplicates skipped)"
            load()
        } catch {
            isBackfilling = false
            backfillStartedAt = nil
            // SB4: a Cancel-button cancellation must read as a plain
            // "Cancelled", not CancellationError's generic localized
            // description.
            backfillError = error is CancellationError ? "Cancelled" : Self.friendlyBackfillError(for: error)
            load()
        }
    }

    /// SB8: `internal/ideas/lock.go`'s alreadyMiningError names the lock
    /// file's absolute path — useful on a terminal, a path leak in a
    /// user-facing dialog. Maps the lock-held case to a plain, actionable
    /// message that names neither the path nor the daemon-vs-CLI internals;
    /// every other error passes through unchanged.
    ///
    /// A pre-flight "Start" button disable (checking lock freshness before
    /// even attempting a run) is deferred: it would need a Go-side status
    /// probe Desktop doesn't have today, since the Desktop layer must not
    /// reach into WorkspaceDir internals it doesn't already know.
    static func friendlyBackfillError(for error: Error) -> String {
        if let cliError = error as? CLIRunnerError,
           case let .nonZeroExit(_, stderr) = cliError,
           stderr.contains("is mining right now") {
            return "Another mining run is in progress (daemon or CLI). Try again later."
        }
        return error.localizedDescription
    }

    /// Parses the LAST non-empty line of the CLI's stdout as the backfill
    /// envelope (`cmd/ideas.go`'s `backfillEnvelope`). In practice `data` is
    /// already just the envelope: `cycle=N` progress lines go to stderr,
    /// which `CLIRunnerProtocol.run` never mixes into the stdout it returns.
    /// The last-line parse is defensive — cheap insurance against a stray
    /// leading line — not a real ignoring-progress-lines requirement. A
    /// small testable static so the parsing logic is covered independently
    /// of the CLI subprocess.
    static func parseBackfillEnvelope(_ data: Data) -> IdeaBackfillEnvelope? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = text.split(separator: "\n", omittingEmptySubsequences: true).last else { return nil }
        return try? JSONDecoder().decode(IdeaBackfillEnvelope.self, from: Data(lastLine.utf8))
    }

    /// Mirrors `parseBackfillEnvelope`'s last-line parse, for GB9's
    /// {"disabled":true} envelope (`cmd/ideas.go`'s `ideasDisabledEnvelope`).
    static func parseDisabledEnvelope(_ data: Data) -> IdeasDisabledEnvelope? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = text.split(separator: "\n", omittingEmptySubsequences: true).last else { return nil }
        return try? JSONDecoder().decode(IdeasDisabledEnvelope.self, from: Data(lastLine.utf8))
    }

}

/// Mirrors `backfillEnvelope` in `cmd/ideas.go` — `ideas mine --from`'s final
/// one-line JSON summary.
struct IdeaBackfillEnvelope: Decodable, Equatable {
    let proposed: Int
    let cycles: Int
    let mentionsDeduped: Int

    private enum CodingKeys: String, CodingKey {
        case proposed, cycles
        case mentionsDeduped = "mentions_deduped"
    }
}

/// Mirrors `ideasDisabledEnvelope` in `cmd/ideas.go` — the backfill path's
/// stdout body when `ideas.enabled=false` (GB9).
struct IdeasDisabledEnvelope: Decodable, Equatable {
    let disabled: Bool
}
