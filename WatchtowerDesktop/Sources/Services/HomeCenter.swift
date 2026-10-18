import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Home's non-DB inputs, injectable for tests.
@MainActor
protocol HomeEnvironment: AnyObject {
    var now: Date { get }
    var calendar: Calendar { get }
    var ownerKnown: Bool { get }
    /// `AppState.ownerPendingSource`.
    var ownerPendingSource: String? { get }
    /// `AppState.firstSyncLine`.
    var firstSync: FirstSyncLine? { get }
    /// `AppState.homeTodayCardsAllowed`.
    var allowedTodayCards: Set<TodayCardKind> { get }
    /// `AppState.homeFeedSourcesAllowed`.
    var feedSourcesAllowed: Set<FeedSource> { get }
}

/// The Getting ready memory, per install: `home.gettingReady.hidden` (Bool),
/// `home.gettingReady.firstShownAt` and `home.gettingReady.completedAt`
/// (Double, unix seconds). A missing key, or a value of another type, reads
/// as false/nil.
@MainActor
final class GettingReadyStore {
    static let hiddenKey = "home.gettingReady.hidden"
    static let firstShownAtKey = "home.gettingReady.firstShownAt"
    static let completedAtKey = "home.gettingReady.completedAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var memory: GettingReadyMemory {
        get {
            GettingReadyMemory(
                hiddenByOwner: defaults.object(forKey: Self.hiddenKey) as? Bool ?? false,
                firstShownAt: date(Self.firstShownAtKey),
                completedAt: date(Self.completedAtKey)
            )
        }
        set {
            defaults.set(newValue.hiddenByOwner, forKey: Self.hiddenKey)
            setDate(newValue.firstShownAt, Self.firstShownAtKey)
            setDate(newValue.completedAt, Self.completedAtKey)
        }
    }

    private func date(_ key: String) -> Date? {
        (defaults.object(forKey: key) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    private func setDate(_ date: Date?, _ key: String) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The Home snapshot, app-wide so it survives tab switches, and the only
/// writer of the Getting ready memory. It re-reads the Today and feed tables
/// on a GRDB observation (this process' writes) and on a 30 s tick (the
/// daemon's writes from another process, which an observation never sees,
/// and the feed's NOW line); a readiness or environment change rebuilds from
/// the last read without touching the DB. It also runs the feed's Done /
/// Hide: the row leaves at once and comes back with its error when the
/// write fails.
@MainActor
@Observable
final class HomeCenter {
    /// nil until the first read.
    private(set) var snapshot: HomeSnapshot?
    /// The last failed Done / Hide per row, cleared by the next press on it
    /// or once a read no longer returns the row.
    private(set) var feedErrors: [FeedRef: String] = [:]
    /// "N more" pressed: every row above NOW shows.
    private(set) var feedExpanded = false

    @ObservationIgnored private let readiness: ReadinessCenter
    @ObservationIgnored private let environment: any HomeEnvironment
    @ObservationIgnored private let store: GettingReadyStore
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let performer: any HomeFeedPerforming
    /// Rows the owner pressed Done / Hide on: left out of the feed while the
    /// write runs, and after it until a read no longer returns them.
    @ObservationIgnored private(set) var hiddenRefs: Set<FeedRef> = []
    /// Rows whose write is still running: a second press does nothing, and a
    /// read landing meanwhile keeps them hidden.
    @ObservationIgnored private var acting: Set<FeedRef> = []
    @ObservationIgnored private var data: HomeTodayData?
    /// The feed read, landed with `data`.
    @ObservationIgnored private var feedData = HomeFeedData()
    /// The pool `beginReading` reads, for `rereadNow`; nil while stopped.
    @ObservationIgnored private var pool: DatabasePool?
    /// The zone showed unready cards during this launch (`GettingReadyPolicy`).
    @ObservationIgnored private var sawUnready = false
    /// Today + feed reads issued; tests check a rebuild did not read.
    @ObservationIgnored private(set) var todayReads = 0
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Bumped by `beginReading`/`endReading`: a read from an earlier run is dropped.
    @ObservationIgnored private var generation = 0
    /// Bumped by every read: an older read landing after a newer one is dropped.
    @ObservationIgnored private var readToken = 0
    /// Bumped by every `rebuildSnapshot`: only the newest input tracking may trigger
    /// another one, so registrations don't pile up.
    @ObservationIgnored private var trackingToken = 0

    init(
        readiness: ReadinessCenter,
        environment: any HomeEnvironment,
        store: GettingReadyStore,
        performer: any HomeFeedPerforming,
        tickInterval: Duration = .seconds(30)
    ) {
        self.readiness = readiness
        self.environment = environment
        self.store = store
        self.performer = performer
        self.tickInterval = tickInterval
    }

    /// Observes the Today and feed tables that exist in this DB (a table missing
    /// mid-migration is left out of the region; the tick still re-reads it)
    /// and starts the tick. A second call restarts both.
    func beginReading(pool: DatabasePool) {
        endReading()
        self.pool = pool
        let current = generation
        observationTask = Task { [weak self] in
            do {
                let tables = try await pool.read { db in
                    try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
                }
                let observed = Set(HomeQueries.observedTables + HomeFeedQueries.observedTables)
                let regions: [any DatabaseRegionConvertible] = observed
                    .filter(tables.contains)
                    .map { Table($0) }
                // A change signal only: the read itself takes `now` from the
                // environment, the same as the tick's.
                let observation = ValueObservation.tracking(regions: regions) { _ in }
                for try await _ in observation.values(in: pool) {
                    guard let self, self.generation == current else { return }
                    await self.reread(pool, generation: current)
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The last snapshot stays; the tick re-reads the DB.
                NSLog("HomeCenter: observing the Home tables: %@", error.localizedDescription)
            }
        }
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                await self.reread(pool, generation: current)
            }
        }
    }

    /// One Today + feed read, in one `pool.read`. Each card's and source's
    /// failure is caught inside `HomeQueries.today` / `HomeFeedQueries.read`;
    /// what lands here is the pool itself failing: every card and source is
    /// marked failed (keeping the last read's content), so Home shows the read
    /// error and Getting ready instead of a spinner, and never an all-clear.
    private func reread(_ pool: DatabasePool, generation current: Int) async {
        readToken += 1
        todayReads += 1
        let token = readToken
        let now = environment.now
        let calendar = environment.calendar
        let value: HomeTodayData
        let feedValue: HomeFeedData
        do {
            (value, feedValue) = try await pool.read { db in
                (HomeQueries.today(db, now: now, calendar: calendar),
                 HomeFeedQueries.read(db, now: now, calendar: calendar))
            }
        } catch {
            NSLog("HomeCenter: reading Home: %@", error.localizedDescription)
            var failed = data ?? HomeTodayData()
            failed.failed = Set(TodayCardKind.allCases)
            value = failed
            var failedFeed = feedData
            failedFeed.failed = Set(FeedSource.allCases)
            feedValue = failedFeed
        }
        guard generation == current, readToken == token else { return }
        data = value
        feedData = feedValue
        forgetGoneRows()
        rebuildSnapshot()
    }

    /// Drops the hidden refs and errors of rows the last read no longer
    /// returns; a row still being written stays hidden.
    private func forgetGoneRows() {
        let hidden = hiddenRefs.filter { acting.contains($0) || Self.contains(feedData, $0) }
        if hidden != hiddenRefs { hiddenRefs = hidden }
        let errors = feedErrors.filter { Self.contains(feedData, $0.key) }
        if errors != feedErrors { feedErrors = errors }
    }

    private static func contains(_ data: HomeFeedData, _ ref: FeedRef) -> Bool {
        switch ref {
        case .inbox(let id): data.inbox.contains { $0.item.id == id }
        case .reminder(let id): (data.dueReminders + data.laterReminders).contains { $0.id == id }
        case .proposal(let id): data.proposals.contains { $0.id == id }
        case .target(let id): data.targets.contains { $0.id == id }
        case .event(let id): data.events.contains { $0.id == id }
        }
    }

    /// Done / Hide on a feed row: the row leaves the feed at once, then the
    /// performer writes it. A failure brings the row back with the error's
    /// text; a success re-reads now (an inbox write comes from the CLI, which
    /// the observation never sees) and the row's hidden mark goes once that
    /// read no longer returns it. A second press while the write runs does
    /// nothing.
    func act(_ action: FeedAction, on ref: FeedRef) async {
        guard !acting.contains(ref) else { return }
        acting.insert(ref)
        hiddenRefs.insert(ref)
        feedErrors[ref] = nil
        rebuildSnapshot()
        do {
            try await performer.perform(action, on: ref, now: environment.now, calendar: environment.calendar)
        } catch {
            NSLog("HomeCenter: %@ on a feed row: %@", "\(action)", error.localizedDescription)
            acting.remove(ref)
            hiddenRefs.remove(ref)
            feedErrors[ref] = error.localizedDescription
            rebuildSnapshot()
            return
        }
        acting.remove(ref)
        await rereadNow()
    }

    /// "N more" / back: every row above NOW, or the first seven.
    func setFeedExpanded(_ on: Bool) {
        guard on != feedExpanded else { return }
        feedExpanded = on
        rebuildSnapshot()
    }

    /// One Today read now, for a write from another process (a CLI call)
    /// the observation never sees; a no-op while stopped.
    func rereadNow() async {
        guard let pool else { return }
        await reread(pool, generation: generation)
    }

    /// Stops the observation and the tick; the last snapshot stays.
    func endReading() {
        generation += 1
        pool = nil
        observationTask?.cancel()
        observationTask = nil
        tickTask?.cancel()
        tickTask = nil
        data = nil
        feedData = HomeFeedData()
        hiddenRefs = acting
        feedErrors = [:]
    }

    /// Rebuilds from the last read and the current readiness, owner, allowed
    /// cards and feed sources and first-sync line, and follows those inputs. A no-op
    /// until the first read, and after `endReading()`.
    func rebuildSnapshot() {
        guard let data else { return }
        trackingToken += 1
        let token = trackingToken
        let inputs = withObservationTracking {
            Inputs(
                readiness: readiness.readiness,
                briefingHour: readiness.briefingHour,
                dayPlanHour: readiness.dayPlanHour,
                ownerKnown: environment.ownerKnown,
                ownerPendingSource: environment.ownerPendingSource,
                firstSync: environment.firstSync,
                allowed: environment.allowedTodayCards,
                feedSources: environment.feedSourcesAllowed
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingToken == token else { return }
                self.rebuildSnapshot()
            }
        }
        let next = makeSnapshot(data, feedData, inputs, now: environment.now, calendar: environment.calendar)
        if next != snapshot { snapshot = next }
    }

    /// The owner's ×: the zone is gone for good on this install.
    func hideGettingReady() {
        var memory = store.memory
        memory.hiddenByOwner = true
        store.memory = memory
        rebuildSnapshot()
    }

    private struct Inputs {
        let readiness: [ReadinessFeature: Readiness]
        let briefingHour: Int
        let dayPlanHour: Int
        let ownerKnown: Bool
        let ownerPendingSource: String?
        let firstSync: FirstSyncLine?
        let allowed: Set<TodayCardKind>
        let feedSources: Set<FeedSource>
    }

    /// Steps the Getting ready policy (persisting what it changed) and builds
    /// the Today cards and the feed.
    private func makeSnapshot(
        _ data: HomeTodayData, _ feedData: HomeFeedData, _ inputs: Inputs, now: Date, calendar: Calendar
    ) -> HomeSnapshot {
        let memory = store.memory
        let step = GettingReadyPolicy.step(
            readiness: inputs.readiness, ownerKnown: inputs.ownerKnown, ownerPendingSource: inputs.ownerPendingSource,
            memory: memory, sawUnready: sawUnready,
            now: now, briefingHour: inputs.briefingHour, dayPlanHour: inputs.dayPlanHour)
        sawUnready = step.sawUnready
        if step.memory != memory { store.memory = step.memory }
        let failed = data.failed.intersection(inputs.allowed)
        return HomeSnapshot(
            gettingReady: step.zone,
            firstSync: inputs.firstSync,
            today: HomeTodayBuilder.cards(data, allowed: inputs.allowed, now: now, calendar: calendar),
            todayReadFailed: !inputs.allowed.isEmpty && inputs.allowed.isSubset(of: failed),
            todayFailed: failed,
            feed: makeFeed(feedData, sources: inputs.feedSources, now: now, calendar: calendar)
        )
    }

    /// The one feed build: a source Home may not show leaves no row and no
    /// failure behind.
    private func makeFeed(_ data: HomeFeedData, sources: Set<FeedSource>, now: Date, calendar: Calendar) -> HomeFeed {
        var data = data
        if !sources.contains(.inbox) { data.inbox = [] }
        if !sources.contains(.reminders) {
            data.dueReminders = []
            data.laterReminders = []
        }
        if !sources.contains(.proposals) { data.proposals = [] }
        if !sources.contains(.targets) { data.targets = [] }
        if !sources.contains(.calendar) {
            data.events = []
            data.prepEventIDs = []
        }
        data.failed.formIntersection(sources)
        return HomeFeedBuilder.feed(data, now: now, calendar: calendar, expanded: feedExpanded, hidden: hiddenRefs)
    }
}

/// Production environment: reads through to AppState, held weakly (AppState
/// owns the center that owns this).
@MainActor
final class LiveHomeEnvironment: HomeEnvironment {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    var now: Date { Date() }
    var calendar: Calendar { .current }
    var ownerKnown: Bool { appState?.owner.isKnown ?? false }
    var ownerPendingSource: String? { appState?.ownerPendingSource }
    var firstSync: FirstSyncLine? { appState?.firstSyncLine }
    var allowedTodayCards: Set<TodayCardKind> { appState?.homeTodayCardsAllowed ?? AppState.homeAlwaysAllowed }
    var feedSourcesAllowed: Set<FeedSource> { appState?.homeFeedSourcesAllowed ?? AppState.homeFeedAlwaysAllowed }
}
