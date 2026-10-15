import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Delivers a plan limit banner; `NotificationService` in the app, a fake in tests.
protocol PlanUsageNotifying {
    func sendPlanUsageNotice(_ notice: PlanUsageNotice)
}

extension NotificationService: PlanUsageNotifying {}

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
    /// After every successful read, not only when the status changed, so a
    /// consumer (the notifier) dedupes itself.
    @ObservationIgnored var onStatus: ((PlanUsageStatus) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let now: () -> Date
    private let notifier: PlanUsageNotifying?
    private let defaults: UserDefaults

    init(
        dbPool: DatabasePool,
        runner: CLIRunnerProtocol?,
        notifier: PlanUsageNotifying? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.runner = runner
        self.notifier = notifier
        self.defaults = defaults
        self.now = now
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.reload()
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
            // Stopped while the read ran: drop the result.
            guard !Task.isCancelled else { return }
            status = fresh
            if let fresh {
                notify(fresh)
                onStatus?(fresh)
            }
        } catch {
            NSLog("PlanUsageCenter: reload failed: %@", String(describing: error))
        }
    }

    /// Runs on every reload; the policy's `sent` set is the only dedupe. A
    /// window counts as sent once it is handed to the notifier, even if
    /// notifications are denied (the `sendSessionAgentNotice` precedent).
    private func notify(_ status: PlanUsageStatus) {
        guard let notifier, defaults.object(forKey: PlanUsageNoticePolicy.enabledKey) as? Bool ?? true else { return }
        // Quiet hours hold the notice back; `sent` is untouched, so one still due fires afterwards.
        guard !defaults.bool(forKey: "quietHoursEnabled") else { return }
        let sent = Set(defaults.stringArray(forKey: PlanUsageNoticePolicy.sentKey) ?? [])
        let result = PlanUsageNoticePolicy.evaluate(status, sent: sent, now: now())
        for notice in result.notices { notifier.sendPlanUsageNotice(notice) }
        if result.sent != sent {
            defaults.set(result.sent.sorted(), forKey: PlanUsageNoticePolicy.sentKey)
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
