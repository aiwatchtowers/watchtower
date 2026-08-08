import Foundation
import GRDB

/// Drives the Ideas & Decisions registry: a review queue (freshly proposed or
/// explicitly flagged ideas) plus a filterable browsable registry of everything
/// else. See `internal/db/ideas.go` on the Go side and `IdeaQueries` for the
/// underlying reads/writes. Structure mirrors `DashboardViewModel`.
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

    /// Master-detail selection. Lives here — the VM is AppState-owned — so
    /// selection survives tab/sidebar navigation.
    var selectedID: Int?

    /// Registry browse filters — ignored by the review queue, which always
    /// shows every proposed/flagged idea regardless of these.
    var kindFilter: String?
    var statusFilter: String?
    var searchText: String = ""

    /// Cap on the registry browse query; the review queue is unbounded (it's
    /// meant to stay small by daily triage).
    private let registryLimit = 200

    private let dbManager: DatabaseManager
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// SB4: retained so cancelBackfill() has something to cancel — started
    /// and cleared by startBackfillTask, the sheet's Start-button entry point.
    private var backfillTask: Task<Void, Never>?

    /// Overrides CLI resolution for tests; production falls back to
    /// `ProcessCLIRunner.makeDefault()` (mirrors `DashboardViewModel`).
    private let cliRunner: CLIRunnerProtocol?

    /// Interval for the safety-net poll. GRDB ValueObservation cannot see writes
    /// from the Go daemon (separate process, separate SQLite update hooks), so
    /// the registry needs a periodic reload to surface daemon-mined ideas.
    private let pollInterval: Duration = .seconds(30)

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

    init(dbManager: DatabaseManager, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
    }

    func select(_ id: Int?) {
        selectedID = id
    }

    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ideas") ?? 0
            }
            .removeDuplicates()
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self?.load()
                }
            } catch {}
        }
        startPolling()
    }

    /// Force an immediate reload from disk. Called on tab-appear so daemon-mined
    /// ideas surface even when the user takes no action while away.
    func refresh() {
        load()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.load()
            }
        }
    }

    func load() {
        isLoading = true
        do {
            let (review, registry) = try dbManager.dbPool.read { db -> ([Idea], [Idea]) in
                let review = try IdeaQueries.fetchForReview(db)
                let registry = try IdeaQueries.fetchList(
                    db,
                    kind: kindFilter,
                    status: statusFilter,
                    query: searchText.isEmpty ? nil : searchText,
                    limit: registryLimit,
                    excludingReviewQueue: true
                )
                return (review, registry)
            }
            reviewItems = review
            registryItems = registry
            errorMessage = nil
            reconcileSelection()
        } catch {
            reviewItems = []
            registryItems = []
            selectedID = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
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

    func approve(_ idea: Idea) {
        write("approve idea") { db in try IdeaQueries.setStatus(db, id: idea.id, status: "active") }
    }

    func reject(_ idea: Idea) {
        write("reject idea") { db in try IdeaQueries.setStatus(db, id: idea.id, status: "rejected") }
    }

    func activate(_ idea: Idea) {
        write("activate idea") { db in try IdeaQueries.setStatus(db, id: idea.id, status: "active") }
    }

    func notNow(_ idea: Idea, until: String = "") {
        write("snooze idea") { db in try IdeaQueries.snooze(db, id: idea.id, until: until.isEmpty ? nil : until) }
    }

    func drop(_ idea: Idea) {
        write("drop idea") { db in try IdeaQueries.setStatus(db, id: idea.id, status: "dropped") }
    }

    func merge(_ idea: Idea, into targetID: Int) {
        write("merge idea") { db in try IdeaQueries.merge(db, id: idea.id, into: targetID) }
    }

    func supersede(_ idea: Idea, by newID: Int?) {
        write("supersede idea") { db in try IdeaQueries.supersede(db, id: idea.id, by: newID) }
    }

    func reverse(_ idea: Idea) {
        write("reverse idea") { db in try IdeaQueries.setStatus(db, id: idea.id, status: "reversed") }
    }

    /// Returns whether the rating landed, so the view can keep the owner's
    /// typed comment on screen when it did not (clear-only-on-success).
    @discardableResult
    func setRating(_ idea: Idea, rating: Int, comment: String = "") -> Bool {
        write("set rating") { db in try IdeaQueries.setRating(db, id: idea.id, rating: rating, comment: comment) }
    }

    @discardableResult
    func createManual(kind: String, title: String, essence: String) -> Int? {
        do {
            let newID = try dbManager.dbPool.write { db in
                try IdeaQueries.createManual(db, kind: kind, title: title, essence: essence)
            }
            load()
            return Int(newID)
        } catch {
            errorMessage = "Failed to create idea: \(error.localizedDescription)"
            return nil
        }
    }

    /// Converts an idea into a Target: creates the target from the idea's
    /// title/essence (`source_type: "idea"`), marks the idea converted with a
    /// link back to it, and returns the new target id so the caller can
    /// navigate via `AppState.navigateToTarget` — mirroring the Dashboard's
    /// situation-to-target conversion flow (`DashboardView`/`CreateTargetSheet`).
    @discardableResult
    func convertToTarget(_ idea: Idea) -> Int? {
        do {
            let today = Self.dateFormatter.string(from: Date())
            let newTargetID = try dbManager.dbPool.write { db -> Int in
                let targetID = try TargetQueries.create(
                    db,
                    text: idea.title,
                    intent: idea.essence,
                    level: "day",
                    periodStart: today,
                    periodEnd: today,
                    sourceType: "idea",
                    sourceID: String(idea.id)
                )
                try IdeaQueries.markConverted(db, id: idea.id, targetID: Int64(targetID))
                return targetID
            }
            load()
            return newTargetID
        } catch {
            errorMessage = "Failed to convert idea to target: \(error.localizedDescription)"
            return nil
        }
    }

    /// Shared write-then-reload helper for the simple status-flip actions above.
    /// Returns whether the write succeeded, so callers that clear owner-typed
    /// input can gate on it.
    @discardableResult
    private func write(_ label: String, _ body: @escaping (Database) throws -> Void) -> Bool {
        do {
            try dbManager.dbPool.write(body)
            load()
            return true
        } catch {
            errorMessage = "Failed to \(label): \(error.localizedDescription)"
            return false
        }
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
