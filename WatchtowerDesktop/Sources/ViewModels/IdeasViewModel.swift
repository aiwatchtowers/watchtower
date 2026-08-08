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

    /// Interval for the safety-net poll. GRDB ValueObservation cannot see writes
    /// from the Go daemon (separate process, separate SQLite update hooks), so
    /// the registry needs a periodic reload to surface daemon-mined ideas.
    private let pollInterval: Duration = .seconds(30)

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    var selectedItem: Idea? {
        guard let id = selectedID else { return nil }
        return reviewItems.first { $0.id == id } ?? registryItems.first { $0.id == id }
    }

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
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
}
