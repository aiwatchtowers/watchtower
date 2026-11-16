import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerInterface

/// The Desktop's side of the tower (mobile Inbox spec §2.3, §3): the one
/// `TowerClient`, its daemon hooks on the start queue, and the tray's
/// Pause Sync / Resume Sync.
extension AppState {
    private static let towerLog = Logger(subsystem: "com.watchtower.desktop", category: "tower")

    /// A daemon start or restart takes `--no-sync`: onboarding has never
    /// finished. "Run setup again" keeps the syncing daemon it had.
    var daemonRunsWithoutSync: Bool {
        needsOnboarding && !isOnboardingRerun
    }

    /// The client over the active workspace's socket (asked again for every
    /// connection, so a workspace onboarding creates is found). Retry after
    /// "isn't running" starts the daemon, a version mismatch restarts it;
    /// both go through the start queue.
    func makeTowerClient() -> TowerClient {
        TowerClient(
            transport: SocketTransport { Constants.activeWorkspaceDir() },
            clock: ContinuousClock(),
            restartDaemon: { [weak self] in await self?.restartDaemonForTower() ?? false },
            startDaemon: { [weak self] in await self?.startDaemonForTower() }
        )
    }

    /// The Inbox reads its lists, counts and badge from the daemon's
    /// `inbox.feed` (the whole tree, no limit, no clip) and sends every
    /// write as `inbox.act`. Only the app does
    /// this; a test run never reaches a daemon (its AppState may still wire
    /// the database the app's way).
    func attachTowerInbox(_ strip: ActionStripViewModel) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        strip.attach(InboxFeedLoader(client: towerClient) { FeedRequest() })
        strip.attachWrites(InboxTowerWrites(client: towerClient))
    }

    /// The sidebar's counts, loaded and observed, with the Inbox badge from
    /// the tower (`towerInboxBadge`).
    func startedSidebarCounts(_ pool: DatabasePool) async -> SidebarCountsViewModel? {
        await SidebarCountsViewModel.started(
            dbPool: pool, disabledFeatures: featureVisibility.disabledFeatureIDs
        ) { [weak self] in await self?.towerInboxBadge() }
    }

    /// The sidebar's Inbox badge from the tower: the open Inbox's last feed,
    /// else one small read beside the screen (`limit: 1`: every folder and
    /// its count, one card). Nil when the Inbox does not read from the tower
    /// (tests) or the tower did not answer: the local count stays.
    func towerInboxBadge() async -> Int? {
        guard let strip = actionStripViewModel, let loader = strip.feedLoader else { return nil }
        if loader.isOpen, let badge = strip.towerBadge { return badge }
        guard let feed: Feed = await towerClient.readAside(.inboxFeed, params: FeedRequest(limit: 1)) else { return nil }
        return InboxRootModel(feed: feed, platform: .mac).countBadge
    }

    /// `TowerClient`'s `startDaemon` (Retry after down): one start on the
    /// queue; a second Retry while it waits joins it.
    func startDaemonForTower() async {
        if let towerDaemonStart {
            await towerDaemonStart.value
            return
        }
        guard let start = startDaemonIfDown(caller: "startDaemonForTower") else { return }
        towerDaemonStart = start
        await start.value
        towerDaemonStart = nil
    }

    /// Starts the daemon on the queue unless one runs (checked when the item
    /// runs), with `--no-sync` before onboarding first finishes. Nil, and no
    /// item, during the launch's database steps.
    @discardableResult
    func startDaemonIfDown(caller: String) -> Task<Void, Never>? {
        guard !daemonStartBlocked(caller) else { return nil }
        let daemon = daemonControl
        return enqueueDaemonStart { [weak self] in
            guard let self, !daemonStartBlocked(caller), !daemon.daemonIsRunning() else { return }
            if await daemon.startDetached(noSync: daemonRunsWithoutSync) {
                daemonStartQueue.succeeded()
            } else {
                daemonStartFailure = Self.daemonStartFailureText(daemonManager.errorMessage)
            }
        }
    }

    /// `TowerClient`'s `restartDaemon` (`tower.hello` answered another
    /// interface version): one restart on the queue, with `--no-sync` before
    /// onboarding first finishes. Whether it went through.
    func restartDaemonForTower() async -> Bool {
        guard !daemonStartBlocked("restartDaemonForTower") else { return false }
        let daemon = daemonControl
        return await enqueueDaemonStart { [weak self] () -> Bool in
            guard let self, !daemonStartBlocked("restartDaemonForTower") else { return false }
            do {
                try await daemon.restartWaiting(noSync: daemonRunsWithoutSync)
                daemonStartQueue.succeeded()
                return true
            } catch {
                daemonStartFailure = Self.daemonRestartFailureText(error)
                return false
            }
        }.value
    }

    /// Reads the owner's pause from `tower.hello` (the tray, when it opens).
    /// A tower that does not answer leaves the last value.
    func refreshSyncPaused() async {
        guard let hello = await towerClient.helloAnswer() else { return }
        syncPaused = hello.syncPaused
    }

    /// The tray's Pause Sync: `sync.pause` (the daemon keeps running).
    func pauseSync() async {
        await setSyncPaused(true)
    }

    /// The tray's Resume Sync: `sync.resume`, then Sync Now, since a resumed
    /// daemon otherwise waits for its next poll tick.
    func resumeSync() async {
        guard await setSyncPaused(false) else { return }
        await daemonManager.syncNow()
    }

    /// Sends `sync.pause` or `sync.resume`; true when the tower said ok. A
    /// refusal or failure shows its sentence on the tray (`syncPauseError`);
    /// an unknown outcome re-reads the state from `tower.hello`.
    @discardableResult
    private func setSyncPaused(_ paused: Bool) async -> Bool {
        let command: TowerCommand = paused ? .syncPause : .syncResume
        let outcome: TowerActOutcome<PauseResponse> = await towerClient.act(command, key: command.rawValue) {
            PauseRequest(requestID: $0)
        }
        switch outcome {
        case .ok(let response):
            syncPaused = response.paused
            syncPauseError = nil
            return true
        case .refused(let sentence):
            syncPauseError = sentence
        case .failed(let failure):
            syncPauseError = failure.sentence
        case .unknown:
            syncPauseError = nil
            await refreshSyncPaused()
        }
        Self.towerLog.error("\(command.rawValue, privacy: .public) did not go through: \(self.syncPauseError ?? "unknown", privacy: .public)")
        return false
    }
}
