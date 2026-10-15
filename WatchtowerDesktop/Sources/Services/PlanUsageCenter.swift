import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Claude plan limits as the app shows them. The daemon poller writes
/// `plan_usage_status` from another process, so GRDB observation never fires:
/// a 30 s poll re-reads it (the `WorkbenchNotificationCenter` shape).
@MainActor
@Observable
final class PlanUsageCenter {
    static let pollInterval: Duration = .seconds(30)
    /// `@AppStorage` key of the "show in menu bar" toggle; absent = on.
    static let menuBarKey = "planUsage.showInMenuBar"

    private(set) var status: PlanUsageStatus?
    private(set) var isRefreshing = false
    /// After every successful read; the notifier hooks in here.
    @ObservationIgnored var onStatus: ((PlanUsageStatus) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let now: () -> Date

    init(dbPool: DatabasePool, runner: CLIRunnerProtocol?, now: @escaping () -> Date = Date.init) {
        self.dbPool = dbPool
        self.runner = runner
        self.now = now
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reload() async {
        do {
            let fresh = try await dbPool.read { try PlanUsageQueries.status($0) }
            status = fresh
            if let fresh { onStatus?(fresh) }
        } catch {
            NSLog("PlanUsageCenter: reload failed: %@", String(describing: error))
        }
    }

    /// Asks the daemon-side poller for a fresh read now. A nonzero exit has
    /// still written the error state, so the reload runs either way.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await runner?.run(args: ["usage", "plan", "--now"])
        } catch {
            NSLog("PlanUsageCenter: usage plan --now failed: %@", String(describing: error))
        }
        await reload()
    }

    func samples(key: String, since: Date) async -> [PlanUsageSample] {
        do {
            return try await dbPool.read { try PlanUsageQueries.samples($0, key: key, since: since) }
        } catch {
            NSLog("PlanUsageCenter: samples failed: %@", String(describing: error))
            return []
        }
    }

    /// "⚠︎ 5h 92% · 7d 59%", the same without the mark, or nil.
    func menuBarLabel(showText: Bool) -> String? {
        guard showText, let text = PlanUsagePresentation.menuBarText(status) else { return nil }
        return PlanUsagePresentation.menuBarWarning(status, now: now()) ? "⚠︎ \(text)" : text
    }

    /// The session and weekly rows of the tray.
    var trayLines: [String] {
        guard let status else { return [] }
        let at = now()
        return ["session", "weekly_all"].compactMap { key in
            status.limits.first { $0.key == key }.map { PlanUsagePresentation.trayLine($0, now: at) }
        }
    }
}
