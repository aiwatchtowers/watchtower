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
        /// The CloudKit transport's store a wipe empties; nil for a
        /// transport that keeps none.
        let transportStorePath: String?
        /// `seqFloor`: the phone's seq ceiling the wiped replica held (F29),
        /// so a new pairing never reuses a seq.
        let make: @MainActor (
            _ scope: CloudDatabaseScope, _ hubID: String, _ device: LinkedDevice?, _ seqFloor: UInt64
        ) throws -> AppEnvironment
    }

    private(set) var env: AppEnvironment
    let linking: LinkingViewModel
    /// Set when a restarted environment could not open (`BootFailureView`).
    private(set) var failure: String?

    @ObservationIgnored private var scope: CloudDatabaseScope
    /// The hub whose zones the running environment syncs.
    @ObservationIgnored private var hubID: String
    @ObservationIgnored private let restarter: Restarter?
    /// The running environment served a link that has ended without a
    /// restart (`retireEnvironment`): the next `prepare` restarts even on
    /// the same database and hub.
    @ObservationIgnored private var retired = false
    /// The restart running or queued last: restarts run one at a time.
    @ObservationIgnored private var restartTask: Task<LocalWipe, Error>?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppRoot")

    /// `restarter` nil keeps `env` for good (the demo, tests).
    init(env: AppEnvironment, scope: CloudDatabaseScope, hubID: String, linking: LinkingViewModel, restarter: Restarter?) {
        self.env = env
        self.scope = scope
        self.hubID = hubID
        self.linking = linking
        self.restarter = restarter
        linking.host = self
        wire(env)
    }

    var isDemo: Bool { env.transportKind == .inMemoryDemo }

    /// Welcome and the scan instead of the tabs: a live build with no link.
    var showsOnboarding: Bool { !isDemo && linking.link == nil }

    /// The app's root: the demo on an unsigned build, else the saved link's
    /// database, resuming a link a kill interrupted. Throws
    /// `KeyStoreError.locked` before the first unlock since a restart (the
    /// boot waits for it).
    static func live() throws -> AppRoot {
        let defaults = UserDefaults.standard
        guard CloudKitTransport.entitlementPresent() else {
            return demo(try AppEnvironment(), defaults: defaults)
        }
        let store = LinkStore(defaults: defaults)
        let keys = try PhoneKeychain.store()
        // F14: reads the device id (works while locked), never creates it.
        let identity = try DeviceIdentity.current(keys: keys)
        LegacyDeviceID.remove(defaults: defaults)
        let make: @MainActor (CloudDatabaseScope, String, LinkedDevice?, UInt64) throws -> AppEnvironment = { scope, hubID, device, floor in
            try AppEnvironment(
                scope: scope, hubID: hubID, linkedDevice: device, keys: PhoneKeys(store: keys, hubID: hubID), seqFloor: floor
            )
        }
        let scope = store.bootScope
        let hubID = store.bootHubID
        let directory = try AppEnvironment.appGroupDirectory()
        let root = AppRoot(
            env: try make(scope, hubID, store.link.flatMap(identity.linkedDevice(for:)), 0),
            scope: scope,
            hubID: hubID,
            linking: LinkingViewModel(container: CloudKitLinkContainer(), store: store, identity: identity, keys: keys),
            restarter: Restarter(
                replicaPath: AppEnvironment.liveReplicaPath(in: directory),
                transportStorePath: AppEnvironment.liveTransportStorePath(in: directory),
                make: make
            )
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
            hubID: AppEnvironment.unlinkedHubID,
            linking: LinkingViewModel(
                container: CloudKitLinkContainer(), store: LinkStore(defaults: defaults), identity: identity,
                keys: InMemoryPhoneKeyStore()
            ),
            restarter: nil
        )
    }

    /// At launch: a link saved before encryption is dropped (scan again),
    /// a link a kill left waiting resumes, then the account check (the
    /// account may have changed while the app was not running).
    func resumeLink() async {
        await linking.dropUnencryptedLink()
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
        env.onKeyboxChanged = { [weak self] in self?.keyboxChanged() }
    }

    /// A keybox indexed in the running environment (a rotation, a removal).
    private func keyboxChanged() {
        guard !isDemo else { return }
        let linking = linking
        Task { await linking.keyboxChanged() }
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
    /// `hubID`'s zones in `scope`'s database; `wipe` first removes the replica and empties the
    /// transport's store (buffered events, send queue, engine state: a
    /// transport reopened on the same scope would otherwise resume from its
    /// saved change token past the compacted prefix and still send the old
    /// queue). Restarts queue behind each other, so two teardowns never
    /// share an environment. No-op for a root without a restarter.
    ///
    /// A wipe never takes the owner's audio silently: a running capture
    /// is stopped and saved first, and every recording still on its way to
    /// the Mac is held for the hub it was recorded for
    /// (`AppEnvironment.handOverRecordings`), unless `keepRecordings` is
    /// false (an iCloud account change), when it is reported "Not sent".
    /// Returns what the wipe lost, counted after the next environment
    /// adopted its hub's held recordings.
    @discardableResult
    private func restart(
        scope: CloudDatabaseScope,
        hubID: String,
        device: LinkedDevice?,
        wipe: Bool,
        keepRecordings: Bool = true
    ) async throws -> LocalWipe {
        guard let restarter else { return LocalWipe() }
        let previous = restartTask
        let task = Task {
            _ = await previous?.result
            return try await self.performRestart(
                scope: scope, hubID: hubID, device: device, wipe: wipe, keepRecordings: keepRecordings, restarter: restarter
            )
        }
        restartTask = task
        return try await task.value
    }

    private func performRestart(
        scope: CloudDatabaseScope,
        hubID: String,
        device: LinkedDevice?,
        wipe: Bool,
        keepRecordings: Bool,
        restarter: Restarter
    ) async throws -> LocalWipe {
        let old = env
        old.onLinkSignal = nil
        old.onFetched = nil
        old.onKeyboxChanged = nil
        let stoppedCapture = wipe ? await old.recorder.stopForWipe() : nil
        // After the shutdown the old boot (and its launch recovery) has
        // ended: the hand-over never races it.
        await old.shutDown()
        var outcome = LocalWipe()
        var seqFloor: UInt64 = 0
        if wipe {
            do {
                seqFloor = try old.envelopeSeqCeiling()
            } catch {
                // Unreadable: the new replica restarts its own ceiling (logged; seqs of a new pairing).
                Self.logger.error("seq ceiling unreadable at the wipe: \(error.localizedDescription, privacy: .public)")
            }
            let handover = await old.handOverRecordings(stoppedCapture: stoppedCapture, keep: keepRecordings)
            outcome = LocalWipe(
                notSent: Self.pendingActionCount(old) + handover.lost,
                stoppedRecording: handover.stoppedCaptureKept,
                problem: handover.problem
            )
        }
        do {
            if wipe {
                try Self.removeReplica(at: restarter.replicaPath)
                if let path = restarter.transportStorePath {
                    try TransportStore(path: path).wipe()
                }
            }
            let next = try restarter.make(scope, hubID, device, seqFloor)
            wire(next)
            env = next
            self.scope = scope
            self.hubID = hubID
            retired = false
            if let adoption = await next.adoption?.value {
                outcome.notSent += adoption.lost
                outcome.problem = outcome.problem ?? adoption.problem
            }
        } catch {
            // The held recordings stay in the hold: the next boot adopts them.
            Self.logger.critical("environment restart failed: \(error.localizedDescription, privacy: .public)")
            failure = error.localizedDescription
            throw error
        }
        return outcome
    }

    /// The replica and its WAL files. The stopped environment's pool may
    /// still hold them open; it reads its unlinked files until it goes. A
    /// file that stays fails the restart (`failure`): a new environment on
    /// it would show the old link's data.
    private static func removeReplica(at path: String) throws {
        for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            do {
                try FileManager.default.removeItem(atPath: file)
            } catch {
                logger.error("replica wipe failed for \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }

    /// Outbox items still waiting for the Mac: what a wipe loses besides
    /// recordings it could not keep ("Not sent").
    private static func pendingActionCount(_ env: AppEnvironment) -> Int {
        do {
            return try env.store.pendingActions().filter { $0.state == .pending }.count
        } catch {
            logger.error("not-sent count failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

// MARK: - LinkHost

extension AppRoot: LinkHost {
    func prepare(scope: CloudDatabaseScope, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport {
        // A queued restart decides the running scope and hub.
        _ = await restartTask?.result
        if fresh || retired || scope != self.scope || hubID != self.hubID {
            // The environment replaced here is an unlinked or retired one:
            // a recording problem is only logged (a scan shows no notice).
            let wipe = try await restart(scope: scope, hubID: hubID, device: nil, wipe: true)
            if let problem = wipe.problem {
                Self.logger.error("recordings at the link restart: \(problem, privacy: .public)")
            }
        }
        return env.linkTransport
    }

    func fetchKeybox(deviceID: String) async -> Keybox? {
        await env.refresh()
        return await storedKeybox(deviceID: deviceID)
    }

    func storedKeybox(deviceID: String) async -> Keybox? {
        guard let id = UUID(uuidString: deviceID) else {
            Self.logger.error("keybox read for a device id that is not a UUID")
            return nil
        }
        do {
            return try env.keybox(deviceID: id)
        } catch {
            Self.logger.error("keybox read failed: \(String(describing: error), privacy: .public)")
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

    func retireEnvironment() {
        retired = true
    }

    func wipeLocalData(restartingOn scope: CloudDatabaseScope, hubID: String, keepRecordings: Bool) async -> LocalWipe {
        do {
            return try await restart(scope: scope, hubID: hubID, device: nil, wipe: true, keepRecordings: keepRecordings)
        } catch {
            // `failure` is set: the app shows BootFailureView.
            return LocalWipe()
        }
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
