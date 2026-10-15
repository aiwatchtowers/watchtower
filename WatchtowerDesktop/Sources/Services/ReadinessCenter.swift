import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The non-DB inputs of `FeatureReadiness`, injectable for tests.
@MainActor
protocol ReadinessEnvironment: AnyObject {
    var now: Date { get }
    var daemonRunning: Bool { get }
    var syncProgress: SyncProgress? { get }
    /// When the last Slack sync finished (`last_sync.json`); nil before the first.
    var lastSyncTime: Date? { get }
    var disabledFeatureIDs: Set<String> { get }
    var connected: ConnectedSources { get }
    var briefingHour: Int { get }
    var dayPlanHour: Int { get }
    /// `sync.poll_interval` as written in config.yaml ("15m").
    var pollInterval: String? { get }
    /// A stamp file in the active workspace directory; missing or garbage → nil.
    func stamp(_ fileName: String) -> Date?
}

/// Live feature readiness, app-wide so a reading survives tab switches. It
/// re-evaluates on a GRDB observation of the content tables and
/// `pipeline_runs` (this process' writes), on any change of the observable
/// inputs the environment reads (the daemon's status poll, the feature/source
/// visibility store), and on a 30 s tick that re-reads the DB — the daemon
/// writes those tables from another process, which a ValueObservation never
/// sees — and rolls scheduled times over.
@MainActor
@Observable
final class ReadinessCenter {
    /// Empty until the first evaluation, which waits for the first DB read.
    private(set) var readiness: [ReadinessFeature: Readiness] = [:]
    /// The hours the last evaluation read, for the empty states' "at or
    /// after HH:00" (Go's `config.DefaultBriefingHour`/`DefaultDayPlanHour` until then).
    private(set) var briefingHour = 8
    private(set) var dayPlanHour = 8

    /// The daemon's throttle stamps read here, a subset of
    /// `DaemonStampFiles.names`.
    static let stampFiles = ["last_people.txt", "last_briefing.txt", "last_ideas.txt", "last_streams.txt"]

    struct DBSnapshot: Equatable, Sendable {
        var contentPresent: Set<ReadinessFeature>
        var latestRuns: [String: RunSnapshot]
    }

    @ObservationIgnored private let environment: any ReadinessEnvironment
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var snapshot: DBSnapshot?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Bumped by `start`/`stop`: a value from an earlier observation is dropped.
    @ObservationIgnored private var generation = 0
    /// Bumped by every `refresh`: only the newest input tracking may trigger
    /// another one, so registrations don't pile up.
    @ObservationIgnored private var trackingToken = 0

    init(environment: any ReadinessEnvironment, tickInterval: Duration = .seconds(30)) {
        self.environment = environment
        self.tickInterval = tickInterval
    }

    /// Observes the content tables that exist in this DB (a table missing
    /// mid-migration is left out of the region, and reads as no content) and
    /// starts the tick. A second call restarts both.
    func start(pool: DatabasePool) {
        stop()
        let current = generation
        observationTask = Task { [weak self] in
            do {
                let tables = try await pool.read { db in
                    try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
                }
                let regions: [any DatabaseRegionConvertible] = ReadinessQueries.observedTables
                    .filter(tables.contains)
                    .map { Table($0) }
                let observation = ValueObservation.tracking(regions: regions, fetch: Self.readSnapshot)
                    .removeDuplicates()
                for try await value in observation.values(in: pool) {
                    guard let self, self.generation == current else { return }
                    self.snapshot = value
                    self.refresh()
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The last reading stays; the tick re-reads the DB.
                NSLog("ReadinessCenter: observing readiness: %@", error.localizedDescription)
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

    private nonisolated static func readSnapshot(_ db: Database) throws -> DBSnapshot {
        DBSnapshot(contentPresent: try ReadinessQueries.contentPresent(db),
                   latestRuns: try ReadinessQueries.latestRuns(db))
    }

    /// The tick's one-shot read: picks up the daemon's writes, and a table a
    /// migration created after `start`. A failed read keeps the last snapshot.
    private func reread(_ pool: DatabasePool, generation current: Int) async {
        do {
            let value = try await pool.read(Self.readSnapshot)
            guard generation == current else { return }
            if value != snapshot { snapshot = value }
        } catch {
            NSLog("ReadinessCenter: re-reading readiness: %@", error.localizedDescription)
        }
        guard generation == current else { return }
        refresh()
    }

    /// Stops the observation and the tick; the last reading stays.
    func stop() {
        generation += 1
        observationTask?.cancel()
        observationTask = nil
        tickTask?.cancel()
        tickTask = nil
        snapshot = nil
    }

    /// Re-reads the non-DB inputs and re-evaluates. A no-op until the first
    /// DB read, and after `stop()`.
    func refresh() {
        guard let snapshot else { return }
        trackingToken += 1
        let token = trackingToken
        let inputs = withObservationTracking {
            makeInputs(snapshot)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingToken == token else { return }
                self.refresh()
            }
        }
        let next = FeatureReadiness.evaluate(inputs)
        if next != readiness { readiness = next }
        if inputs.briefingHour != briefingHour { briefingHour = inputs.briefingHour }
        if inputs.dayPlanHour != dayPlanHour { dayPlanHour = inputs.dayPlanHour }
    }

    func readiness(for feature: ReadinessFeature) -> Readiness? {
        readiness[feature]
    }

    private func makeInputs(_ snapshot: DBSnapshot) -> ReadinessInputs {
        ReadinessInputs(
            now: environment.now,
            disabledFeatureIDs: environment.disabledFeatureIDs,
            connected: environment.connected,
            daemonRunning: environment.daemonRunning,
            syncProgress: environment.syncProgress,
            lastSyncTime: environment.lastSyncTime,
            latestRuns: snapshot.latestRuns,
            contentPresent: snapshot.contentPresent,
            stamps: ReadinessStamps(
                lastPeople: environment.stamp("last_people.txt"),
                lastBriefing: environment.stamp("last_briefing.txt"),
                lastIdeas: environment.stamp("last_ideas.txt"),
                lastStreams: environment.stamp("last_streams.txt")
            ),
            briefingHour: environment.briefingHour,
            dayPlanHour: environment.dayPlanHour,
            pollIntervalMinutes: FeatureReadiness.parsePollInterval(environment.pollInterval)
        )
    }
}

/// Production environment: AppState's `DaemonManager` and
/// `FeatureVisibilityStore`, config.yaml through a `ConfigService`, stamps
/// from the active workspace directory.
@MainActor
final class LiveReadinessEnvironment: ReadinessEnvironment {
    private let daemon: DaemonManager
    private let visibility: FeatureVisibilityStore
    private let workspaceDir: () -> String?
    private let configPath: String
    /// One parse of config.yaml serves the three reads of a refresh.
    private var config: ConfigService?
    private var configReadAt = Date.distantPast
    private static let configMaxAge: TimeInterval = 1

    init(
        daemon: DaemonManager,
        visibility: FeatureVisibilityStore,
        configPath: String = Constants.configPath,
        workspaceDir: @escaping () -> String?
    ) {
        self.daemon = daemon
        self.visibility = visibility
        self.configPath = configPath
        self.workspaceDir = workspaceDir
    }

    var now: Date { Date() }
    var daemonRunning: Bool { daemon.isRunning }
    var syncProgress: SyncProgress? { daemon.syncProgress }
    var lastSyncTime: Date? { daemon.lastSyncTime }
    var disabledFeatureIDs: Set<String> { visibility.disabledFeatureIDs }
    var connected: ConnectedSources { visibility.connectedSources }
    var briefingHour: Int { currentConfig().briefingHour }
    var dayPlanHour: Int { currentConfig().dayPlanHour }
    var pollInterval: String? { currentConfig().syncInterval }

    /// Stamp files are a dual-path contract with Go's `saveLastPeople`,
    /// `saveLastBriefing`, `saveLastIdeas`, `saveLastStreams`
    /// (internal/daemon/daemon.go): decimal unix seconds. Missing, unreadable
    /// or not a number all read as "no stamp", the same as the daemon's
    /// `loadLast*` does.
    func stamp(_ fileName: String) -> Date? {
        guard let dir = workspaceDir(),
              let text = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(fileName), encoding: .utf8),
              let seconds = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func currentConfig() -> ConfigService {
        if let config, Date().timeIntervalSince(configReadAt) < Self.configMaxAge { return config }
        let fresh = ConfigService(configPath: configPath)
        config = fresh
        configReadAt = Date()
        return fresh
    }
}
