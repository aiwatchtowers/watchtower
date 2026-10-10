import Foundation
import Observation
import os
import UserNotifications
import WatchtowerSync

/// The app's root for its lifetime: the current `AppEnvironment` and the
/// link flow, which restarts the environment when the link needs another
/// database or an empty replica (spec §2.3, §9). A transport serves one
/// database for its lifetime, and the replica has no wipe of its own, so a
/// scope change or a wipe builds a new environment on the same files (the
/// replica's removed first).
///
/// The demo (unsigned builds) keeps one environment, linked as
/// `DemoSeed.device`, and never shows onboarding.
@MainActor
@Observable
final class AppRoot {
    /// How a live root builds its next environment.
    struct Restarter {
        /// The replica file a wipe removes.
        let replicaPath: String
        let make: @MainActor (_ scope: CloudDatabaseScope, _ device: LinkedDevice?) throws -> AppEnvironment
    }

    private(set) var env: AppEnvironment
    let linking: LinkingViewModel
    /// Set when a restarted environment could not open (`BootFailureView`).
    private(set) var failure: String?

    @ObservationIgnored private var scope: CloudDatabaseScope
    @ObservationIgnored private let restarter: Restarter?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppRoot")

    /// `restarter` nil keeps `env` for good (the demo, tests).
    init(env: AppEnvironment, scope: CloudDatabaseScope, linking: LinkingViewModel, restarter: Restarter?) {
        self.env = env
        self.scope = scope
        self.linking = linking
        self.restarter = restarter
        linking.host = self
        wire(env)
    }

    var isDemo: Bool { env.transportKind == .inMemoryDemo }

    /// Welcome and the scan instead of the tabs: a live build with no link.
    var showsOnboarding: Bool { !isDemo && linking.link == nil }

    /// The app's root: the demo on an unsigned build, else the saved link's
    /// database, resuming a link a kill interrupted.
    static func live() throws -> AppRoot {
        let defaults = UserDefaults.standard
        guard CloudKitTransport.entitlementPresent() else {
            return demo(try AppEnvironment(), defaults: defaults)
        }
        let store = LinkStore(defaults: defaults)
        let identity = DeviceIdentity.current(defaults: defaults)
        let make: @MainActor (CloudDatabaseScope, LinkedDevice?) throws -> AppEnvironment = { scope, device in
            try AppEnvironment(scope: scope, linkedDevice: device)
        }
        let scope = store.bootScope
        let root = AppRoot(
            env: try make(scope, store.link.map(identity.linkedDevice(for:))),
            scope: scope,
            linking: LinkingViewModel(container: CloudKitLinkContainer(), store: store, identity: identity),
            restarter: Restarter(replicaPath: AppEnvironment.liveReplicaPath(in: try AppEnvironment.appGroupDirectory()), make: make)
        )
        Task { await root.resumeLink() }
        return root
    }

    /// A root that keeps `env` for good: the demo, linked as
    /// `DemoSeed.device`.
    static func demo(_ env: AppEnvironment, defaults: UserDefaults) -> AppRoot {
        let device = DemoSeed.device
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        return AppRoot(
            env: env,
            scope: .private,
            linking: LinkingViewModel(container: CloudKitLinkContainer(), store: LinkStore(defaults: defaults), identity: identity),
            restarter: nil
        )
    }

    /// At launch: a link a kill left waiting, then the account check (the
    /// account may have changed while the app was not running).
    func resumeLink() async {
        await linking.resumePendingLink()
        await linking.accountChanged()
    }

    /// A `watchtower://link` URL from the system Camera app. The demo has no
    /// link to change.
    func open(_ url: URL) async {
        guard !isDemo else {
            Self.logger.notice("link URL ignored: the demo build has no link")
            return
        }
        await linking.open(url)
    }

    // MARK: - Environment

    private func wire(_ env: AppEnvironment) {
        env.onLinkSignal = { [weak self] signal in self?.handle(signal) }
        env.onFetched = { [weak self] in self?.checkHeartbeat() }
    }

    private func handle(_ signal: LinkSignal) {
        let linking = linking
        Task {
            switch signal {
            case .unlinked: await linking.removedByMac()
            case .accountChanged: await linking.accountChanged()
            }
        }
    }

    /// The heartbeat after each fetch: the moved and stale checks.
    private func checkHeartbeat() {
        guard !isDemo, linking.link != nil else { return }
        let store = env.store
        let heartbeat: HeartbeatPayload?
        do {
            heartbeat = try store.reader.read { db in
                try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
            }
        } catch {
            Self.logger.error("heartbeat read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let linking = linking
        Task { await linking.evaluate(heartbeat: heartbeat) }
    }

    /// Shuts the current environment down and builds the next one on
    /// `scope`'s database; `wipe` removes the replica first. No-op for a
    /// root without a restarter.
    private func restart(scope: CloudDatabaseScope, device: LinkedDevice?, wipe: Bool) async throws {
        guard let restarter else { return }
        let old = env
        old.onLinkSignal = nil
        old.onFetched = nil
        await old.shutDown()
        if wipe {
            Self.removeReplica(at: restarter.replicaPath)
        }
        do {
            let next = try restarter.make(scope, device)
            wire(next)
            env = next
            self.scope = scope
        } catch {
            Self.logger.critical("environment restart failed: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
            throw error
        }
    }

    /// The replica and its WAL files. The stopped environment's pool may
    /// still hold them open; it reads its unlinked files until it goes.
    private static func removeReplica(at path: String) {
        for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            do {
                try FileManager.default.removeItem(atPath: file)
            } catch {
                logger.error("replica wipe failed for \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Outbox items and recordings still waiting for the Mac: what a wipe
    /// loses ("Not sent").
    private func notSentCount() -> Int {
        do {
            let actions = try env.store.pendingActions().filter { $0.state == .pending }.count
            let recordings = try env.store.phoneRecordings().filter { [.recording, .waiting, .uploading].contains($0.state) }.count
            return actions + recordings
        } catch {
            Self.logger.error("not-sent count failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

// MARK: - LinkHost

extension AppRoot: LinkHost {
    func prepare(scope: CloudDatabaseScope) async throws -> any CloudSyncTransport {
        if scope != self.scope {
            try await restart(scope: scope, device: nil, wipe: true)
        }
        return env.linkTransport
    }

    func fetchGrant(deviceID: String) async -> DeviceGrant? {
        await env.refresh()
        let store = env.store
        do {
            return try await store.reader.read { db in
                try SettingsSnapshot.decode(
                    DeviceGrant.self,
                    recordName: SliceKind.deviceGrant.recordName(id: deviceID),
                    store: store,
                    from: db
                )
            }
        } catch {
            Self.logger.error("grant read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func setLink(_ device: LinkedDevice?, writesAllowed: Bool) async {
        await env.setLinkedDevice(device, writesAllowed: writesAllowed)
    }

    func devicePayload(for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload {
        env.deviceSettings.devicePayload(for: device, linkNonce: linkNonce, unlinked: unlinked, now: now)
    }

    func flushSends() async {
        await env.sendNow()
    }

    func wipeLocalData() async -> Int {
        let notSent = notSentCount()
        do {
            try await restart(scope: .private, device: nil, wipe: true)
        } catch {
            // `failure` is set: the app shows BootFailureView.
        }
        return notSent
    }

    func requestNotificationPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Self.logger.warning("notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openNow() {
        env.navigation.tab = .now
    }
}
