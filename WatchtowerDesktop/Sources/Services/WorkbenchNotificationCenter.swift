import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Native-push seam (the `MeetingReminderNotifying` shape), so the center is
/// testable without `UNUserNotificationCenter`.
protocol WorkbenchNotifying {
    func sendWorkbenchNotice(_ notice: WorkbenchNotice)
}

extension NotificationService: WorkbenchNotifying {}

/// One project's activity read, seamed so a test can fail a single project
/// without corrupting the shared database for every other one.
protocol WorkbenchActivityReading {
    func snapshot(_ db: Database, project: Workbench, afterAgentCommentID: Int64) throws -> WorkbenchNotificationPolicy.Snapshot
}

struct DefaultWorkbenchActivityReader: WorkbenchActivityReading {
    func snapshot(_ db: Database, project: Workbench, afterAgentCommentID: Int64) throws -> WorkbenchNotificationPolicy.Snapshot {
        try WorkbenchQueries.activitySnapshot(db, project: project, afterAgentCommentID: afterAgentCommentID)
    }
}

/// Owner notifications for project activity (spec §6.5). A 30 s poll — the
/// agent writes from another process (the project MCP server), so GRDB
/// observation never fires. Per project it compares the persisted snapshot
/// with the current one through the pure `WorkbenchNotificationPolicy`.
@MainActor
@Observable
final class WorkbenchNotificationCenter {
    /// `@AppStorage` key of the Settings toggle; absent = on.
    static let enabledKey = "projects.notifications"
    static let pollInterval: Duration = .seconds(30)

    static func snapshotKey(_ projectID: Int64) -> String { "projects.notificationSnapshot.\(projectID)" }

    /// After every poll — the Projects list reloads here (its data changes in
    /// other processes too).
    @ObservationIgnored var onPolled: (() async -> Void)?

    @ObservationIgnored private var ownerTouched: [Int64: Set<WorkbenchSubject>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let dbPool: DatabasePool
    private let notifier: WorkbenchNotifying
    private let activityReader: WorkbenchActivityReading
    private let defaults: UserDefaults

    init(
        dbPool: DatabasePool,
        notifier: WorkbenchNotifying = NotificationService.shared,
        activityReader: WorkbenchActivityReading = DefaultWorkbenchActivityReader(),
        defaults: UserDefaults = .standard
    ) {
        self.dbPool = dbPool
        self.notifier = notifier
        self.activityReader = activityReader
        self.defaults = defaults
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The owner changed `subject`: the next poll must not report it.
    func recordOwnerWrite(projectID: Int64, subject: WorkbenchSubject) {
        ownerTouched[projectID, default: []].insert(subject)
    }

    /// A project created in-app starts from an empty baseline, so what Claude
    /// Code attaches during setup is reported (a project the center merely
    /// discovers baselines silently instead).
    func seedBaseline(project: Workbench) {
        save(.empty(projectID: project.id, projectName: project.name))
    }

    private var sending: Bool {
        let enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        return enabled && !defaults.bool(forKey: "quietHoursEnabled")
    }

    func poll() async {
        let projects: [Workbench]
        do {
            projects = try await dbPool.read { try WorkbenchQueries.fetchAll($0) }
        } catch {
            // Nothing to iterate and nothing to prune against: bail before
            // touching either.
            print("[ProjectNotifications] poll error: \(error.localizedDescription)")
            await onPolled?()
            return
        }
        // One project's read failing (a race with its own delete, a
        // transient I/O error) must not skip every other project's poll —
        // T18: log and move on rather than aborting the whole cycle.
        for project in projects {
            do {
                try await poll(project)
            } catch {
                print("[ProjectNotifications] poll error for project \(project.id): \(error.localizedDescription)")
            }
        }
        prune(keeping: Set(projects.map(\.id)))
        await onPolled?()
    }

    private func poll(_ project: Workbench) async throws {
        let previous = load(project.id)
        let touchedBefore = ownerTouched[project.id] ?? []
        let watermark = previous?.lastAgentCommentID ?? 0
        var current = try await dbPool.read {
            try self.activityReader.snapshot($0, project: project, afterAgentCommentID: watermark)
        }
        // Writes recorded while the read ran stay pending for the next poll
        // too: their effect may or may not be in this snapshot.
        current.ownerTouched = ownerTouched[project.id] ?? []
        ownerTouched[project.id] = current.ownerTouched.subtracting(touchedBefore)
        if let previous, sending {
            for notice in WorkbenchNotificationPolicy.decide(previous: previous, current: current) {
                notifier.sendWorkbenchNotice(notice)
            }
        }
        save(current.persisted)
    }

    private func load(_ projectID: Int64) -> WorkbenchNotificationPolicy.Snapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey(projectID)) else { return nil }
        do {
            return try JSONDecoder().decode(WorkbenchNotificationPolicy.Snapshot.self, from: data)
        } catch {
            // Undecodable ≠ absent: say so, then re-baseline silently rather
            // than replay the project's whole history.
            print("[ProjectNotifications] snapshot for project \(projectID) unreadable, re-baselining: \(error)")
            return nil
        }
    }

    private func save(_ snapshot: WorkbenchNotificationPolicy.Snapshot) {
        do {
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey(snapshot.projectID))
        } catch {
            print("[ProjectNotifications] could not save snapshot for project \(snapshot.projectID): \(error)")
        }
    }

    private func prune(keeping ids: Set<Int64>) {
        let prefix = Self.snapshotKey(0).dropLast()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            if let id = Int64(key.dropFirst(prefix.count)), !ids.contains(id) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
