import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Inbox's Watchman entry (spec §10): the list of nights and the
/// selected night's journal — Waiting for you, Decided, Checks nobody ran,
/// the gaps the Mac slept through and the night's cost. App-wide on
/// `AppState`; it reads only (the owner's OK / Correct… are Task 17).
@MainActor
@Observable
final class WatchmanJournalViewModel {
    /// One read: the newest nights and the items being decided now.
    struct Snapshot: Equatable, Sendable {
        var nights: [WatchmanNight]
        var deciding: [WatchmanItem]
        /// What the decided items leaned on, by precedent id.
        var precedents: [Int64: String] = [:]
    }

    enum Phase: Equatable { case loading, empty, failed, journal }

    /// One row of the night list.
    struct NightRow: Identifiable, Equatable {
        let id: Date
        let title: String
        let line: String
        let live: Bool
        let selected: Bool
    }

    /// A card of Waiting for you or of Decided.
    struct Card: Identifiable, Equatable {
        let id: Int64
        let place: String
        let question: String
        /// The Unsure badge; nil on a waiting card.
        let badge: String?
        let reason: String?
        let choice: String?
        let rationale: String?
        let precedents: [String]
        let meta: String
        let outcome: String?
        let handed: Bool
    }

    /// A one-line decision (sure) or a check nobody ran.
    struct Line: Identifiable, Equatable {
        let id: Int64
        let title: String
        let note: String?
        let meta: String
    }

    /// The selected night as the reading pane draws it.
    struct Page: Equatable {
        let title: String
        let span: String
        let gapLines: [String]
        let cost: String
        let busyLine: String?
        let waiting: [Card]
        let decided: [Card]
        let sureLines: [Line]
        let decidedCount: Int
        let decidedSummary: String
        let checks: [Line]
    }

    /// How many nights the list reads.
    nonisolated static let nightLimit = 30

    private(set) var phase: Phase = .loading
    private(set) var snapshot = Snapshot(nights: [], deciding: [])
    /// The night the pane shows; nil = the newest.
    var selectedNight: Date?
    /// The workbench the journal is narrowed to; nil = all.
    var scope: Int64?
    /// `watchman status --json`'s `daemon_running`.
    var daemon: WatchmanDaemonState = .unknown

    @ObservationIgnored private let read: @Sendable () async throws -> Snapshot
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let pool: DatabasePool?
    /// Bumped by every read: an older reply never overwrites a newer one.
    @ObservationIgnored private var readToken = 0

    init(
        read: @escaping @Sendable () async throws -> Snapshot,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        pool: DatabasePool? = nil
    ) {
        self.read = read
        self.now = now
        self.calendar = calendar
        self.pool = pool
    }

    /// The journal over the app's database.
    convenience init(pool: DatabasePool, calendar: Calendar = .current) {
        self.init(read: {
            try await pool.read { db in
                let nights = try WatchmanJournalQueries.nights(db, limit: Self.nightLimit, calendar: calendar)
                let ids = Set(nights.flatMap { $0.items.flatMap(\.precedentIDs) })
                return Snapshot(nights: nights, deciding: try WatchmanJournalQueries.liveDeciding(db),
                                precedents: try WatchmanJournalQueries.precedentTitles(db, ids: ids))
            }
        }, calendar: calendar, pool: pool)
    }

    // MARK: - Reads

    func load() async {
        readToken += 1
        let token = readToken
        let result: Result<Snapshot, Error>
        do {
            result = .success(try await read())
        } catch {
            result = .failure(error)
        }
        guard token == readToken else { return }
        if case .failure(let error) = result, error is CancellationError { return }
        apply(result)
    }

    /// Takes one read's outcome. A failure while a night is on screen
    /// keeps the night (the next change rereads).
    func apply(_ result: Result<Snapshot, Error>) {
        switch result {
        case .success(let next):
            snapshot = next
            phase = next.nights.isEmpty ? .empty : .journal
        case .failure(let error):
            NSLog("WatchmanJournal: reading the journal: %@", error.localizedDescription)
            if phase != .journal { phase = .failed }
        }
    }

    func retry() async {
        phase = .loading
        await load()
    }

    /// Reads now and again whenever the journal's tables change, until
    /// the calling task ends (the pane's `.task`).
    func watch() async {
        await load()
        guard let pool else { return }
        let regions: [any DatabaseRegionConvertible] = WatchmanJournalQueries.observedTables.map { Table($0) }
        let observation = ValueObservation.tracking(regions: regions) { _ in }
        do {
            for try await _ in observation.values(in: pool).dropFirst() {
                guard !Task.isCancelled else { return }
                await load()
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("WatchmanJournal: observing the journal: %@", error.localizedDescription)
        }
    }

    // MARK: - Copy

    var title: String { WatchmanJournalCopy.title }
    var loadingText: String { WatchmanJournalCopy.loading }
    var readFailedText: String { WatchmanJournalCopy.readFailed }
    var retryTitle: String { WatchmanJournalCopy.retry }
    var emptyHint: String { WatchmanJournalCopy.emptyHint }
    var emptyCopy: EmptyStateCopy {
        EmptyStateCopyTable.copy(for: WatchmanJournalCopy.emptyCopyKey, briefingHour: 0)
            ?? EmptyStateCopy(icon: "moon.stars", title: "", landsHere: "", feature: nil, primaryAction: nil)
    }

    var daemonLine: String? { daemon == .stopped ? WatchmanJournalCopy.daemonStopped : nil }

    var waitingTitle: String { WatchmanJournalCopy.waitingTitle }
    var decidedTitle: String { WatchmanJournalCopy.decidedTitle }
    var checksTitle: String { WatchmanJournalCopy.checksTitle }
    var choseLabel: String { WatchmanJournalCopy.choseLabel }
    var leanedOn: String { WatchmanJournalCopy.leanedOn }

    // MARK: - Scope

    var scopeTitle: String {
        scope.flatMap { id in scopeOptions.first { $0.id == id }?.name } ?? WatchmanJournalCopy.scopeAll
    }

    /// Every workbench with an item in the nights read, by name.
    var scopeOptions: [(id: Int64, name: String)] {
        var names: [Int64: String] = [:]
        for item in snapshot.nights.flatMap(\.items) where names[item.workbenchID] == nil {
            names[item.workbenchID] = item.workbenchName.isEmpty ? "#\(item.workbenchID)" : item.workbenchName
        }
        return names.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: - Nights

    /// The nights in scope, newest first.
    var nights: [WatchmanNight] {
        snapshot.nights.map { $0.scoped(to: scope) }.filter { !$0.items.isEmpty }
    }

    var nightRows: [NightRow] {
        let shown = shownNight?.date
        return nights.map { night in
            let live = isLive(night)
            return NightRow(id: night.date, title: nightTitle(night), line: WatchmanJournalCopy.nightListLine(night, live: live),
                            live: live, selected: night.date == shown)
        }
    }

    var page: Page? {
        guard let night = shownNight else { return nil }
        let live = isLive(night)
        let unsure = night.decided.filter(\.unsure)
        let sure = night.decided.filter { !$0.unsure }
        let deciding = snapshot.deciding.filter { scope == nil || $0.workbenchID == scope }
        return Page(
            title: nightTitle(night),
            span: WatchmanJournalCopy.nightSpan(night, live: live, calendar: calendar),
            gapLines: night.gaps.map { WatchmanJournalCopy.gapLine($0, calendar: calendar) },
            cost: WatchmanJournalCopy.cost(night.costUSD, tonight: isTonight(night)),
            busyLine: live ? deciding.first.map { WatchmanJournalCopy.deciding($0.question) } : nil,
            waiting: night.waiting.map(waitingCard),
            decided: unsure.map(decidedCard),
            sureLines: sure.map(sureLine),
            decidedCount: night.decided.count,
            decidedSummary: WatchmanJournalCopy.decidedSummary(unsure: unsure.count, sure: sure.count),
            checks: night.checks.map(checkLine)
        )
    }

    // MARK: - Private

    private var shownNight: WatchmanNight? {
        let nights = nights
        return nights.first { $0.date == selectedNight } ?? nights.first
    }

    private func isTonight(_ night: WatchmanNight) -> Bool {
        night.date == WatchmanNight.start(of: now(), calendar: calendar)
    }

    /// Tonight with an item still queued or being decided.
    private func isLive(_ night: WatchmanNight) -> Bool {
        isTonight(night) && !night.pending.isEmpty
    }

    private func nightTitle(_ night: WatchmanNight) -> String {
        WatchmanJournalCopy.nightTitle(night.date, now: now(), calendar: calendar)
    }

    private func sureLine(_ item: WatchmanItem) -> Line {
        Line(id: item.id, title: WatchmanJournalCopy.question(item), note: nil, meta: WatchmanJournalCopy.meta(item))
    }

    private func checkLine(_ item: WatchmanItem) -> Line {
        Line(id: item.id, title: WatchmanJournalCopy.question(item), note: WatchmanJournalCopy.checkLine,
             meta: WatchmanJournalCopy.place(item, calendar: calendar))
    }

    private func waitingCard(_ item: WatchmanItem) -> Card {
        Card(id: item.id, place: WatchmanJournalCopy.place(item, calendar: calendar),
             question: WatchmanJournalCopy.question(item), badge: nil,
             reason: WatchmanJournalCopy.waitingReason(item), choice: nil, rationale: nil, precedents: [],
             meta: WatchmanJournalCopy.meta(item), outcome: nil, handed: item.outcome == "handed")
    }

    private func decidedCard(_ item: WatchmanItem) -> Card {
        Card(id: item.id, place: WatchmanJournalCopy.place(item, calendar: calendar),
             question: WatchmanJournalCopy.question(item), badge: WatchmanJournalCopy.unsureBadge, reason: nil,
             choice: item.choice.isEmpty ? nil : item.choice,
             rationale: item.rationale.isEmpty ? nil : item.rationale,
             precedents: item.precedentIDs.compactMap { snapshot.precedents[$0] },
             meta: WatchmanJournalCopy.meta(item), outcome: WatchmanJournalCopy.outcome(item), handed: false)
    }
}
