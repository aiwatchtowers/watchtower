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
    static let featureID = "claude-plan-limits"

    private(set) var status: PlanUsageStatus?
    private(set) var codexStatus: PlanUsageStatus?
    private(set) var readErrors: [PlanUsageProvider: PlansOperationError] = [:]
    private(set) var refreshErrors: [PlanUsageProvider: PlansOperationError] = [:]
    private(set) var refreshingProviders: Set<PlanUsageProvider> = []
    private(set) var loadedProviders: Set<PlanUsageProvider> = []
    private(set) var featureEnabled = true
    var isRefreshing: Bool { !refreshingProviders.isEmpty }
    /// The tray's history backfill line (`BackfillProgress.line`); nil when
    /// nothing loads. Rides this poll so the tray needs no timer of its own.
    private(set) var backfillLine: String?
    /// After every successful read, not only when the status changed, so a
    /// consumer (the notifier) dedupes itself.
    @ObservationIgnored var onStatus: ((PlanUsageStatus) -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTasks: [PlanUsageProvider: Task<PlansOperationError?, Never>] = [:]
    @ObservationIgnored private var refreshIDs: [PlanUsageProvider: UUID] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var featureRevision = 0
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
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        for task in refreshTasks.values { task.cancel() }
        refreshTasks = [:]
        refreshIDs = [:]
        refreshingProviders = []
    }

    func reload() async {
        let epoch = generation
        await reloadBackfillLine()
        guard !Task.isCancelled, epoch == generation else { return }
        async let claude: Void = reload(.claude, expectedGeneration: epoch)
        async let codex: Void = reload(.codex, expectedGeneration: epoch)
        _ = await (claude, codex)
    }

    /// A successful Feature Manager load is current config evidence. Retained
    /// DB numbers never turn a feature back on after a disabled refresh.
    func setFeatureEnabled(_ enabled: Bool) {
        featureRevision += 1
        featureEnabled = enabled
        if enabled {
            refreshErrors = refreshErrors.filter { $0.value.code != "feature_disabled" }
        }
    }

    func providerStatus(_ provider: PlanUsageProvider) -> PlanUsageStatus? {
        provider == .claude ? status : codexStatus
    }

    func providerError(_ provider: PlanUsageProvider) -> PlansOperationError? {
        readErrors[provider] ?? refreshErrors[provider]
    }

    func presentation(_ provider: PlanUsageProvider, at date: Date? = nil) throws -> PlansProviderPresentation {
        try PlansPresentation.card(provider: provider, status: providerStatus(provider), error: providerError(provider),
                                   refreshing: refreshingProviders.contains(provider) || !loadedProviders.contains(provider),
                                   now: date ?? now(), enabled: featureEnabled)
    }

    private func reload(
        _ provider: PlanUsageProvider,
        clearOlderRefreshError: Bool = true,
        expectedGeneration: Int? = nil
    ) async {
        let epoch = expectedGeneration ?? generation
        guard !Task.isCancelled, epoch == generation else { return }
        let previousFetched = providerStatus(provider)?.fetchedAt
        do {
            let fresh = try await dbPool.read { try PlanUsageQueries.status($0, provider: provider) }
            // Stopped while the read ran: drop the result.
            guard !Task.isCancelled, epoch == generation else { return }
            if provider == .claude { status = fresh } else { codexStatus = fresh }
            if clearOlderRefreshError, fresh?.state == "ok", fresh?.fetchedAt != previousFetched {
                refreshErrors[provider] = nil
            }
            loadedProviders.insert(provider)
            readErrors[provider] = nil
            if provider == .claude, let fresh {
                notify(fresh)
                onStatus?(fresh)
            }
        } catch {
            guard !Task.isCancelled, epoch == generation else { return }
            // Hide the failed provider's retained values instead of freezing them as current.
            if provider == .claude { status = nil } else { codexStatus = nil }
            loadedProviders.insert(provider)
            readErrors[provider] = PlansOperationError(code: "storage")
            NSLog("PlanUsageCenter: %@ snapshot read failed", provider.rawValue)
        }
    }

    /// Its own read, so a failure here cannot freeze the plan status; a failed
    /// read keeps the last line.
    private func reloadBackfillLine() async {
        let epoch = generation
        do {
            let line = try await dbPool.read { BackfillProgress.line(try BackfillQueries.rows($0)) }
            guard !Task.isCancelled, epoch == generation else { return }
            if line != backfillLine { backfillLine = line }
        } catch {
            NSLog("PlanUsageCenter: backfill read failed: %@", String(describing: error))
        }
    }

    /// Runs on every reload; the policy's `sent` set is the only dedupe. A
    /// window counts as sent once it is handed to the notifier, even if
    /// notifications are denied (the `sendSessionAgentNotice` precedent).
    private func notify(_ status: PlanUsageStatus) {
        guard featureEnabled, let notifier, defaults.object(forKey: PlanUsageNoticePolicy.enabledKey) as? Bool ?? true else { return }
        // A pause holds the notice back; `sent` is untouched, so one still due fires afterwards.
        guard !NotificationPreferences.isPaused(defaults) else { return }
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
        async let claude = refresh(.claude)
        async let codex = refresh(.codex)
        _ = await (claude, codex)
    }

    @discardableResult
    func refresh(_ provider: PlanUsageProvider) async -> PlansOperationError? {
        if let existing = refreshTasks[provider] { return await existing.value }
        let id = UUID()
        let epoch = generation
        let featureEpoch = featureRevision
        let task = Task { [weak self] () -> PlansOperationError? in
            guard let self else { return PlansOperationError(code: "cancelled") }
            let result = await self.performRefresh(provider)
            guard !Task.isCancelled, self.generation == epoch else { return PlansOperationError(code: "cancelled") }
            if result?.code == "feature_disabled", self.featureEnabled, self.featureRevision != featureEpoch {
                self.refreshErrors[provider] = nil
            } else {
                self.refreshErrors[provider] = result
            }
            await self.reload(provider, clearOlderRefreshError: false)
            return result
        }
        refreshTasks[provider] = task
        refreshIDs[provider] = id
        refreshingProviders.insert(provider)
        let result = await task.value
        if refreshIDs[provider] == id {
            refreshTasks[provider] = nil
            refreshIDs[provider] = nil
            refreshingProviders.remove(provider)
        }
        return result
    }

    private func performRefresh(_ provider: PlanUsageProvider) async -> PlansOperationError? {
        guard let runner else { return PlansOperationError(code: "storage") }
        let featureEpoch = featureRevision
        do {
            let result = try await runner.capture(args: ["usage", "plans", "--json", "--now", "--provider", provider.rawValue], timeout: 50)
            try Task.checkCancellation()
            let envelope = try PlansEnvelope.decode(result.stdout)
            guard envelope.requestedProvider == provider.rawValue, envelope.refreshRequested,
                  let item = envelope.providers.first else { return PlansOperationError(code: "parse") }
            if featureRevision == featureEpoch { featureEnabled = envelope.featureEnabled }
            if let error = item.error { return error }
            return result.exitCode == 0 ? nil : PlansOperationError(code: "storage")
        } catch is CancellationError { return PlansOperationError(code: "cancelled") } catch {
            NSLog("PlanUsageCenter: %@ refresh failed", provider.rawValue)
            return PlansOperationError(code: "parse")
        }
    }

    func samples(key: String, since: Date) async -> [PlanUsageSample] {
        status?.history[key, default: []].filter { $0.takenAt >= since } ?? []
    }

    /// "⚠︎ 5h 92% · 7d 59%", the same without the mark, or nil.
    func menuBarLabel(showText: Bool) -> String? {
        guard featureEnabled else { return nil }
        do { return try PlansPresentation.menuBar(claude: status, codex: codexStatus, show: showText, now: now()) } catch {
            NSLog("PlanUsageCenter: menu snapshot is invalid")
            return nil
        }
    }

    /// The session and weekly rows of the tray.
    var trayLines: [String] {
        guard featureEnabled else { return [] }
        return [status, codexStatus].compactMap { $0 }.flatMap { status in
            do { return try PlansPresentation.tray(status, now: now()) } catch {
                NSLog("PlanUsageCenter: tray snapshot is invalid")
                return []
            }
        }
    }
}
