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
    /// `AppState.firstSyncLine`.
    var firstSync: FirstSyncLine? { get }
    /// `AppState.homeTodayCardsAllowed`.
    var allowedTodayCards: Set<TodayCardKind> { get }
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
/// writer of the Getting ready memory. It re-reads the Today tables on a GRDB
/// observation (this process' writes) and on a 30 s tick (the daemon's writes
/// from another process, which an observation never sees, and the meeting
/// eyebrow's minutes); a readiness or environment change rebuilds from the
/// last read without touching the DB.
@MainActor
@Observable
final class HomeCenter {
    /// nil until the first read.
    private(set) var snapshot: HomeSnapshot?

    @ObservationIgnored private let readiness: ReadinessCenter
    @ObservationIgnored private let environment: any HomeEnvironment
    @ObservationIgnored private let store: GettingReadyStore
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var data: HomeTodayData?
    /// The zone showed unready cards during this launch (`GettingReadyPolicy`).
    @ObservationIgnored private var sawUnready = false
    /// Today reads issued; tests check a rebuild did not read.
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
        tickInterval: Duration = .seconds(30)
    ) {
        self.readiness = readiness
        self.environment = environment
        self.store = store
        self.tickInterval = tickInterval
    }

    /// Observes the Today tables that exist in this DB (a table missing
    /// mid-migration is left out of the region; the tick still re-reads it)
    /// and starts the tick. A second call restarts both.
    func beginReading(pool: DatabasePool) {
        endReading()
        let current = generation
        observationTask = Task { [weak self] in
            do {
                let tables = try await pool.read { db in
                    try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
                }
                let regions: [any DatabaseRegionConvertible] = HomeQueries.observedTables
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
                NSLog("HomeCenter: observing the Today tables: %@", error.localizedDescription)
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

    /// One Today read. Each card's failure is caught inside `HomeQueries.today`;
    /// what lands here is the pool itself failing, which keeps the last read.
    private func reread(_ pool: DatabasePool, generation current: Int) async {
        readToken += 1
        todayReads += 1
        let token = readToken
        let now = environment.now
        let calendar = environment.calendar
        do {
            let value = try await pool.read { db in HomeQueries.today(db, now: now, calendar: calendar) }
            guard generation == current, readToken == token else { return }
            data = value
        } catch {
            NSLog("HomeCenter: reading Today: %@", error.localizedDescription)
        }
        guard generation == current else { return }
        rebuildSnapshot()
    }

    /// Stops the observation and the tick; the last snapshot stays.
    func endReading() {
        generation += 1
        observationTask?.cancel()
        observationTask = nil
        tickTask?.cancel()
        tickTask = nil
        data = nil
    }

    /// Rebuilds from the last Today read and the current readiness, owner,
    /// allowed cards and first-sync line, and follows those inputs. A no-op
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
                firstSync: environment.firstSync,
                allowed: environment.allowedTodayCards
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingToken == token else { return }
                self.rebuildSnapshot()
            }
        }
        let next = makeSnapshot(data, inputs, now: environment.now, calendar: environment.calendar)
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
        let firstSync: FirstSyncLine?
        let allowed: Set<TodayCardKind>
    }

    /// Steps the Getting ready policy (persisting what it changed) and builds
    /// the Today cards.
    private func makeSnapshot(_ data: HomeTodayData, _ inputs: Inputs, now: Date, calendar: Calendar) -> HomeSnapshot {
        let memory = store.memory
        let step = GettingReadyPolicy.step(
            readiness: inputs.readiness, ownerKnown: inputs.ownerKnown, memory: memory, sawUnready: sawUnready,
            now: now, briefingHour: inputs.briefingHour, dayPlanHour: inputs.dayPlanHour)
        sawUnready = step.sawUnready
        if step.memory != memory { store.memory = step.memory }
        let failed = data.failed.intersection(inputs.allowed)
        return HomeSnapshot(
            gettingReady: step.zone,
            firstSync: inputs.firstSync,
            today: HomeTodayBuilder.cards(data, allowed: inputs.allowed, now: now, calendar: calendar),
            todayReadFailed: !inputs.allowed.isEmpty && inputs.allowed.isSubset(of: failed),
            todayFailed: failed
        )
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
    var firstSync: FirstSyncLine? { appState?.firstSyncLine }
    var allowedTodayCards: Set<TodayCardKind> { appState?.homeTodayCardsAllowed ?? AppState.homeAlwaysAllowed }
}
