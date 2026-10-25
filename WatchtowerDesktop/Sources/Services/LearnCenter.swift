import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Learn zone's non-DB inputs, injectable for tests.
@MainActor
protocol LearnEnvironment: AnyObject {
    var now: Date { get }
    /// nil until `features list` first loaded.
    var disabledFeatures: Set<String>? { get }
    var iphonePaired: Bool { get }
    var dictationUsed: Bool { get }
    /// The onboarding goals of the last Continue.
    var goals: Set<OnboardingGoal> { get }
}

/// Home's Learn Watchtower zone (design §9): the guide's cards, read once per
/// launch from `watchtower guide learn --json` and kept in memory, and the
/// selection over them, rebuilt from the seen rows and signals on a GRDB
/// observation of `LearnQueries.observedTables` (this process' writes), a
/// tick (accounts and other processes' writes, the dictation flag), and
/// any change of the environment's observable inputs. It is the only writer
/// of `learn_seen`: the `in_use` rows the selector returns, Got it, a pressed
/// button and Show again. A catalog that fails to load hides the zone.
@MainActor
@Observable
final class LearnCenter {
    typealias CatalogLoader = @Sendable () async throws -> LearnCatalog

    /// nil until the catalog and the first read landed, and for good when the
    /// catalog failed to load.
    private(set) var selection: LearnSelection?
    /// Seen-row writes that landed. Observable so a test can wait on one; no
    /// view reads it.
    private(set) var writes = 0

    /// What the zone shows: nil hides it (not loaded, failed, or no cards).
    var zone: LearnSelection? {
        guard let selection, selection.total > 0 else { return nil }
        return selection
    }

    @ObservationIgnored private let environment: any LearnEnvironment
    @ObservationIgnored private let loadCatalog: CatalogLoader
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var catalog: LearnCatalog?
    /// The one load of this launch ran (it may have failed).
    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var pool: DatabasePool?
    @ObservationIgnored private var newAfter: LearnVersion?
    @ObservationIgnored private var rows: Rows?
    /// `in_use` ids being written, so a rebuild meanwhile does not write them again.
    @ObservationIgnored private var recording: Set<String> = []
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var trackingToken = 0

    /// The database side of one read.
    private struct Rows {
        let seen: [String: LearnSeenHow]
        let signals: Set<LearnSignal>
        let connected: ConnectedSources
    }

    init(environment: any LearnEnvironment, loadCatalog: @escaping CatalogLoader, tickInterval: Duration = .seconds(30)) {
        self.environment = environment
        self.loadCatalog = loadCatalog
        self.tickInterval = tickInterval
    }

    /// Loads the catalog (once per launch), then reads on every change of the
    /// observed tables and on the tick. `newAfter` is
    /// `LearnVersionPolicy.newAfter` for this launch. A second call restarts.
    func start(pool: DatabasePool, newAfter: LearnVersion?) {
        stop()
        self.pool = pool
        self.newAfter = newAfter
        let current = generation
        observationTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCatalogOnce()
            guard self.generation == current, self.catalog != nil else { return }
            await self.observe(pool, generation: current)
        }
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                await self.refresh()
            }
        }
    }

    /// Stops reading; the catalog and the last selection stay.
    func stop() {
        generation += 1
        pool = nil
        observationTask?.cancel()
        observationTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    /// One read now; a no-op before the catalog loaded or while stopped.
    func refresh() async {
        guard let pool, catalog != nil else { return }
        await reread(pool, generation: generation)
    }

    /// Got it: the card is seen.
    func gotIt(_ id: String) async {
        await record([id], how: .gotIt)
    }

    /// The card's button was pressed (before its action runs).
    func recordAction(_ id: String) async {
        await record([id], how: .action)
    }

    /// Show again (See all): the card is unseen until the next Got it, button or use.
    func showAgain(_ id: String) async {
        guard let pool else { return }
        do {
            try await pool.write { try LearnQueries.showAgain($0, id: id) }
        } catch {
            NSLog("LearnCenter: Show again on %@: %@", id, error.localizedDescription)
            return
        }
        writes += 1
        await refresh()
    }

    private func loadCatalogOnce() async {
        guard !catalogLoaded else { return }
        catalogLoaded = true
        do {
            catalog = try await loadCatalog()
        } catch {
            // The zone stays hidden until the next launch.
            NSLog("LearnCenter: reading the Learn cards: %@", error.localizedDescription)
        }
    }

    private func observe(_ pool: DatabasePool, generation current: Int) async {
        do {
            let existing = try await pool.read { db in
                try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            }
            let regions: [any DatabaseRegionConvertible] = Set(LearnQueries.observedTables)
                .filter(existing.contains)
                .map { Table($0) }
            let observation = ValueObservation.tracking(regions: regions) { _ in }
            for try await _ in observation.values(in: pool) {
                guard generation == current else { return }
                await reread(pool, generation: current)
            }
        } catch {
            guard !Task.isCancelled else { return }
            // The last selection stays; the tick re-reads.
            NSLog("LearnCenter: observing the Learn tables: %@", error.localizedDescription)
        }
    }

    /// The seen rows, row signals and connected sources in one read. A
    /// failure keeps the last selection (the tick tries again).
    private func reread(_ pool: DatabasePool, generation current: Int) async {
        let read: Rows
        do {
            read = try await pool.read { db in
                Rows(seen: try LearnQueries.fetchSeen(db), signals: try LearnQueries.rowSignals(db),
                     connected: try ConnectedSources.fetch(db))
            }
        } catch {
            NSLog("LearnCenter: reading the seen cards: %@", error.localizedDescription)
            return
        }
        guard generation == current else { return }
        rows = read
        rebuild()
    }

    /// Selects from the last read and the environment, follows the
    /// environment's observable inputs, and writes the `in_use` rows.
    private func rebuild() {
        guard let catalog, let rows else { return }
        trackingToken += 1
        let token = trackingToken
        let (disabled, paired, goals) = withObservationTracking {
            (environment.disabledFeatures, environment.iphonePaired, environment.goals)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingToken == token else { return }
                self.rebuild()
            }
        }
        let app = LearnAppState(
            connected: rows.connected, disabledFeatures: disabled, iphonePaired: paired,
            dictationUsed: environment.dictationUsed)
        let signals = LearnInputs.signals(rows: rows.signals, app: app)
        let next = LearnSelector.select(LearnSelectorInput(
            catalog: catalog, seen: rows.seen, signals: signals,
            metRequirements: LearnInputs.metRequirements(catalog, signals: signals, app: app),
            goals: goals, newAfter: newAfter))
        if next != selection { selection = next }
        let inUse = next.recordInUse.filter { !recording.contains($0) }
        if !inUse.isEmpty {
            Task { await self.record(inUse, how: .inUse) }
        }
    }

    private func record(_ ids: [String], how: LearnSeenHow) async {
        guard let pool else { return }
        recording.formUnion(ids)
        defer { recording.subtract(ids) }
        let now = environment.now
        do {
            try await pool.write { try LearnQueries.markSeen($0, ids: ids, how: how, now: now) }
        } catch {
            NSLog("LearnCenter: recording %@ as %@: %@", ids.joined(separator: ","), how.rawValue,
                  error.localizedDescription)
            return
        }
        writes += 1
        await refresh()
    }
}

/// Production environment: reads through to AppState, held weakly (AppState
/// owns the center that owns this).
@MainActor
final class LiveLearnEnvironment: LearnEnvironment {
    private weak var appState: AppState?
    private let defaults: UserDefaults

    init(appState: AppState, defaults: UserDefaults = .standard) {
        self.appState = appState
        self.defaults = defaults
    }

    var now: Date { Date() }
    var disabledFeatures: Set<String>? {
        guard let visibility = appState?.featureVisibility, visibility.isLoaded else { return nil }
        return visibility.disabledFeatureIDs
    }
    var iphonePaired: Bool { !(appState?.mobileLinkCenter?.devices.isEmpty ?? true) }
    var dictationUsed: Bool { defaults.bool(forKey: LearnInputs.dictationUsedKey) }
    var goals: Set<OnboardingGoal> { appState?.onboardingGoals.savedGoals ?? [] }

    /// `watchtower guide learn --json` through the installed CLI.
    nonisolated static func loadCatalog() async throws -> LearnCatalog {
        guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
        let data = try await runner.run(args: ["guide", "learn", "--json"], timeout: 30)
        return try JSONDecoder().decode(LearnCatalog.self, from: data)
    }
}
