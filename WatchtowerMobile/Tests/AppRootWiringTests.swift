import CryptoKit
import Foundation
import GRDB
import os
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// `AppRoot` as the link flow's host over the hub registry (multi-hub F2,
/// spec §5.7, §6): a scan builds the scanned hub's session in its own
/// directories, a link adds a row and activates it, a removal deletes one
/// hub's files and row and holds its recordings, the Mac's removal freezes
/// only its hub, and the demo never onboards. E2E: every session seals and
/// opens with the test pairing (`TestE2E`): the hub's records reach its
/// transport sealed by the test hub, and what the phone writes is opened
/// the way the Mac opens it.
@MainActor
final class AppRootWiringTests: XCTestCase {
    /// The test pairing's phone (`TestE2E`): the hub seals its grant to
    /// this device id.
    private let device = LinkedDevice(
        deviceID: TestPhone.deviceID(),
        name: "Colleague A's iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    /// Every session the factory built, with its database, hub and
    /// in-memory transport (nil over a persistent store).
    private var built: [(session: HubSession, scope: CloudDatabaseScope, hubID: String, transport: InMemoryCloudTransport?)] = []
    /// The factory gives sessions no keys (a test of a link made before E2E).
    private var withholdKeys = false
    /// Every session's recorder runs on this engine and clock: no audio.
    private let engine = FakeAudioEngine()
    private let clock = FakeClock()
    private var paths: HubPaths!
    private var registry: HubRegistry!
    private var defaults: UserDefaults!
    private var container: FakeLinkContainer!
    /// Each look at an unlink's `unlinked` record in its hub's send queue:
    /// the hub, the record, and whether the session was still running.
    private var farewellChecks: [(hubID: String, record: CloudRecord, running: Bool)] = []
    /// The farewell never leaves the send queue (a network that never
    /// answers); `farewellCap` bounds the wait.
    private var farewellStuck = false
    private var farewellCap: Duration = .seconds(10)
    /// The send step never returns (a network that hangs): only the cap
    /// ends the wait.
    private var farewellSendHangs = false
    /// Every resend of a kept farewell (#143), and whether one goes out.
    private var farewellResends: [PendingFarewell] = []
    private var farewellResendSucceeds = false
    /// The hung sends, resumed at teardown so no task outlives the test.
    private var hungSends: [CheckedContinuation<Void, Never>] = []
    /// Hubs whose session the factory cannot build (a replica that will
    /// not open): it throws after preparing their directories.
    private var failingHubs: Set<String> = []
    /// Background work the root began and ended, by name.
    private var workBegun: [String] = []
    private var workEnded: [String] = []
    /// The phone's Keychain stand-in, shared by every session and the link
    /// flow (as the Keychain is): the test pairing's identity and the test
    /// hub's link.
    private var keyStore: InMemoryPhoneKeyStore!

    private func makePaths() throws -> HubPaths {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("app-root-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("group", isDirectory: true),
            localDirectory: base.appendingPathComponent("local", isDirectory: true),
            recordingsBase: base.appendingPathComponent("phone-recordings", isDirectory: true)
        )
        for directory in [paths.groupDirectory, paths.localDirectory, paths.recordingsBase] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return paths
    }

    /// A saved link of this phone (`device`), granted at `linkedAt`.
    private func linkRecord(
        _ hubID: String = TestHub.acme,
        macName: String = "Acme Mac",
        deviceID: String? = TestPhone.deviceID(),
        linkedAt: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> LinkRecord {
        LinkRecord(
            hubID: hubID, macName: macName, scope: .private, ownerName: "_owner-acme",
            userRecordName: "_owner-acme", nonce: "nonce-\(hubID)", dataShareURL: nil, relayShareURL: nil,
            deviceID: deviceID, linkedAt: linkedAt
        )
    }

    /// Sessions as the live factory lays them out (`paths`), each over a
    /// fresh in-memory transport, or a `CloudKitTransport` on the hub's
    /// persistent store (`persistentTransport`; no engine starts in the
    /// unsigned test host). Every session gets its own hub's keys
    /// (`TestHub`); a hub id that is not a UUID gets none (key-less).
    private func makeFactory(persistentTransport: Bool = false) throws -> HubSessionFactory {
        let paths = try XCTUnwrap(paths)
        let defaults = try XCTUnwrap(defaults)
        let keyStore = try XCTUnwrap(keyStore)
        let engine = engine
        let clock = clock
        return HubSessionFactory { [weak self] _, hubID, scope, device in
            try paths.prepare(hubID)
            if self?.failingHubs.contains(hubID) == true {
                throw CocoaError(.fileReadCorruptFile)
            }
            let transport: any CloudSyncTransport
            var memory: InMemoryCloudTransport?
            var transportStore: TransportStore?
            if persistentTransport {
                let store = try TransportStore(path: paths.transportStorePath(hubID))
                transportStore = store
                transport = CloudKitTransport(store: store, scope: scope, hubID: hubID, role: .phone)
            } else {
                let created = InMemoryCloudTransport()
                memory = created
                transport = created
            }
            let session = try HubSession(
                transport: transport,
                replicaPath: paths.replicaPath(hubID),
                transportKind: .cloudKit,
                transportStore: transportStore,
                hubID: hubID,
                linkedDevice: device,
                // Each hub's own keys (`TestHub`), linked in the shared store; none while a test withholds them
                // (a link made before E2E).
                keys: try (self?.withholdKeys ?? false) ? nil : TestHub.keys(hubID, store: keyStore),
                defaults: defaults,
                recordingsDirectory: paths.recordingsDirectory(hubID),
                hold: RecordingHold(directory: paths.holdDirectory),
                databaseScope: scope
            ) { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil
                )
            }
            // Runs before the temp directory's removal (teardown blocks run
            // last-in first-out): the boot has ended and the replica's
            // handles are closed, so nothing writes a file already unlinked.
            self?.addTeardownBlock { @MainActor in
                await session.shutDown()
                try? session.store.reader.close()
            }
            self?.built.append((session, scope, hubID, memory))
            return session
        }
    }

    /// A live-kind root over a registry holding `links` (in order; `frozen`
    /// ones in `unlinked_by_mac`), `active` on screen (else the first).
    /// `linkClock` runs the flow's grant wait.
    private func makeRoot(
        links: [LinkRecord] = [],
        active: String? = nil,
        frozen: Set<String> = [],
        linkClock: any LinkClock = SystemLinkClock(),
        persistentTransport: Bool = false,
        keyStore given: InMemoryPhoneKeyStore? = nil,
        beforeLaunch: ((HubPaths) throws -> Void)? = nil
    ) throws -> AppRoot {
        let keyStore = try given ?? TestE2E.phoneStore()
        self.keyStore = keyStore
        paths = try makePaths()
        try beforeLaunch?(paths)
        defaults = try makeDefaults()
        registry = try HubRegistry(path: paths.registryPath)
        for link in links {
            try registry.upsert(link, now: Date())
            if frozen.contains(link.hubID) {
                try registry.setState(.unlinkedByMac, for: link.hubID)
            }
        }
        if let active {
            try registry.setActive(active)
        }
        container = FakeLinkContainer(log: LinkEventLog())
        let identity = DeviceIdentity(
            deviceID: try keyStore.deviceID()?.uuidString, name: device.name, model: device.model, appVersion: device.appVersion
        )
        let factory = try makeFactory(persistentTransport: persistentTransport)
        let env = try AppEnvironment.live(
            registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults
        ) { _ in }
        let send: @MainActor (HubSession) async -> Void = { [weak self] session in
            guard self?.farewellSendHangs == true else {
                await session.sendNow()
                return
            }
            await withCheckedContinuation { self?.hungSends.append($0) }
        }
        let resend: @MainActor (PendingFarewell) async -> Bool = { [weak self] farewell in
            self?.farewellResends.append(farewell)
            return self?.farewellResendSucceeds ?? false
        }
        let starter: BackgroundWork.Starter = { [weak self] name in
            self?.workBegun.append(name)
            return { self?.workEnded.append(name) }
        }
        return AppRoot(
            env: env,
            registry: registry,
            paths: paths,
            factory: factory,
            identity: identity,
            defaults: defaults,
            linking: LinkingViewModel(
                container: container, store: LinkStore(defaults: defaults), identity: identity, keys: keyStore, clock: linkClock
            ),
            startWork: starter,
            farewellDelivery: AppRoot.FarewellDelivery(
                isPending: { [weak self] session, record in
                    self?.farewellChecks.append((session.hubID, record, session.isLooping))
                    return self?.farewellStuck ?? false
                },
                cap: farewellCap,
                pause: .milliseconds(20),
                send: send,
                resend: resend
            )
        )
    }

    /// The in-memory transport of `hubID`'s latest session.
    private func transport(_ hubID: String) throws -> InMemoryCloudTransport {
        try XCTUnwrap(built.last { $0.hubID == hubID }?.transport, "no session of \(hubID)")
    }

    private func session(_ root: AppRoot, _ hubID: String) throws -> HubSession {
        try XCTUnwrap(root.env.session(hubID), "no session of \(hubID)")
    }

    private func sliceCount(_ session: HubSession) throws -> Int {
        try session.store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0 }
    }

    private func hubFilesExist(_ hubID: String) -> [Bool] {
        [paths.hubDirectory(hubID), paths.localHubDirectory(hubID), paths.recordingsDirectory(hubID)]
            .map { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Removal (multi-hub spec §5.7)

    func testRemovalEmptiesTheHubsReplicaAndOutboxAndCountsWhatWasNotSent() async throws {
        let root = try makeRoot(links: [linkRecord()])
        let first = try session(root, TestHub.acme)
        let now = Date()
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // The safety poll waits a minute after the boot (board #724), and a refresh joins a hydration in flight
        // (sealing makes the launch fetch long enough to miss the save): fetch once the boot is done.
        await root.env.waitForBoot()
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCount(first)) == 1 }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        XCTAssertEqual(try first.store.pendingActions().count, 3)

        let notSent = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        XCTAssertEqual(notSent, LocalWipe(notSent: 3), "the three pending items are reported Not sent")
        XCTAssertNil(root.env.session(TestHub.acme), "the session is gone")
        XCTAssertFalse(first.isLooping, "and stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.replicaPath(TestHub.acme)), "the replica is deleted")
        XCTAssertNil(try registry.row(TestHub.acme))
        XCTAssertNil(root.env.activeHubID)
        XCTAssertTrue(root.showsOnboarding, "no hub left: onboarding")
    }

    /// Finding 1 of the F1 task review, per hub: the removal deletes the
    /// hub's persistent transport store (buffered events, the send queue,
    /// the engine state), so a relink of that hub starts from scratch and
    /// the removed hub's queue never goes out.
    func testRemovalAlsoDeletesThePersistentTransportStore() async throws {
        let root = try makeRoot(links: [linkRecord()], persistentTransport: true)
        let first = try session(root, TestHub.acme)
        try await poll { first.isBootstrapped }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        let transportPath = paths.transportStorePath(TestHub.acme)
        let before = try await transportCounts(try DatabaseQueue(path: transportPath))
        XCTAssertEqual(before.pending, 3, "the outbox's sends wait in the transport queue")

        let notSent = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        XCTAssertEqual(notSent, LocalWipe(notSent: 3))
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: transportPath + suffix), "the transport store\(suffix) is deleted")
        }
        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false])
    }

    /// Ruling 2: the row goes before the removal's first wait, so a kill
    /// anywhere in it (here: held in the hand-over, a save running) never
    /// brings the hub back at the next launch.
    func testARemovalTakesTheRowBeforeItsFirstWait() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")])
        let first = try session(root, TestHub.acme)
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(15)
        engine.holdFinish = true
        let ownerStop = Task { await first.recorder.stop() }
        try await poll { first.recorder.phase == .saving && self.engine.finishCount == 1 }

        let removal = Task { await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil) }
        try await poll { (try? self.registry.row(TestHub.acme)) == nil }

        XCTAssertTrue(root.env.session(TestHub.acme) === first, "the hand-over is still waiting for the save")
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        let relaunched = try AppEnvironment.live(
            registry: registry, paths: paths, factory: try makeFactory(), identity: identity, defaults: defaults
        ) { _ in }
        XCTAssertEqual(relaunched.order, [TestHub.home], "a launch now would not bring the hub back")
        XCTAssertEqual(relaunched.activeHubID, TestHub.home)
        engine.releaseFinish()
        _ = await removal.value
        await ownerStop.value
    }

    /// Two removals of one hub at once (an unlink and a removal signal):
    /// the second finds the first running and counts nothing; a waiting
    /// recording is held once, for its hub.
    func testTwoRemovalsOfOneHubRemoveItOnceAndAWaitingRecordingSurvives() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)

        async let one = root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)
        async let two = root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)
        let wipes = await [one, two]

        XCTAssertEqual(wipes, [LocalWipe(), LocalWipe()], "nothing lost, no capture running")
        XCTAssertEqual(built.map(\.hubID).filter { $0 == TestHub.acme }.count, 1, "no session is rebuilt")
        XCTAssertEqual(root.env.activeHubID, TestHub.home)
        let held = try XCTUnwrap(root.env.heldRecordings.first)
        XCTAssertEqual(held.id, id)
        XCTAssertEqual(held.hubID, TestHub.acme)
        XCTAssertEqual(try hold.load().count, 1, "held once")
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: paths.recordingsDirectory(TestHub.acme)))
    }

    func testUnlinkingTheActiveHubActivatesTheNextAndTheLastReturnsToOnboarding() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)
        XCTAssertFalse(root.showsOnboarding)

        await root.linking.unlink(TestHub.acme)

        XCTAssertEqual(root.env.activeHubID, TestHub.home, "the next Mac in order")
        XCTAssertEqual(try registry.activeHubID, TestHub.home)
        XCTAssertEqual(root.env.order, [TestHub.home])
        XCTAssertEqual(root.linking.links.map(\.hubID), [TestHub.home])
        XCTAssertFalse(root.showsOnboarding)

        await root.linking.unlink(TestHub.home)

        XCTAssertNil(root.env.activeHubID, "ruling 6: no active hub left dangling")
        XCTAssertNil(root.env.active)
        XCTAssertTrue(root.env.sessions.isEmpty)
        XCTAssertTrue(try registry.rows().isEmpty)
        XCTAssertTrue(root.showsOnboarding)
        XCTAssertEqual(farewellChecks.map(\.hubID), [TestHub.acme, TestHub.home], "each unlink waited for its farewell")
    }

    /// An inactive hub's unlink leaves the hub on screen where it is.
    func testUnlinkingAnInactiveHubKeepsTheActiveOne() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)

        await root.linking.unlink(TestHub.home)

        XCTAssertEqual(root.env.activeHubID, TestHub.acme)
        XCTAssertEqual(root.env.order, [TestHub.acme])
    }

    func testUnlinkDeletesTheHubsFilesAndHoldsItsRecordings() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)
        try await poll { root.env.activeSession.isBootstrapped }
        await root.env.deviceSettings.setTypingRequested(true)
        XCTAssertNotNil(defaults.object(forKey: "hub.\(TestHub.acme).device.typingRequested"))
        let id = try await saveVoiceNote(root)
        try await poll { root.env.activeSession.isLooping }

        await root.linking.unlink(TestHub.acme)

        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false], "its replica, transport and audio folders are gone")
        XCTAssertEqual(hubFilesExist(TestHub.home), [true, true, true], "the other hub's stay")
        let held = try XCTUnwrap(try hold.load().first, "the hold manifest names the unsent recording")
        XCTAssertEqual(held.id, id)
        XCTAssertEqual(held.hubID, TestHub.acme)
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: paths.recordingsDirectory(TestHub.acme)))
        XCTAssertNil(defaults.object(forKey: "hub.\(TestHub.acme).device.typingRequested"), "ruling 5: its Workbench choices go")
        XCTAssertEqual(root.linking.notice, nil, "nothing was lost")
        try await assertTheFarewellWentThroughTheHubsOwnTransport(TestHub.acme)
    }

    /// Fix round 1, I1: the `unlinked` record goes through the removed
    /// hub's own transport (it holds the record's server state), while its
    /// session still runs, and the removal waited for it to leave the queue.
    private func assertTheFarewellWentThroughTheHubsOwnTransport(_ hubID: String, line: UInt = #line) async throws {
        let check = try XCTUnwrap(farewellChecks.first, "the removal looked at the send queue", line: line)
        XCTAssertEqual(check.hubID, hubID, line: line)
        XCTAssertTrue(check.running, "sent before the session stops", line: line)
        let sent = try await deviceWrites(in: try transport(hubID))
        XCTAssertEqual(sent.last?.unlinked, true, "the hub's own transport carried it", line: line)
        XCTAssertEqual(check.record.kind, WireKind.envelope, "the queue is looked at for the sealed record", line: line)
    }

    /// Fix round 1, I1: a farewell that never leaves the queue holds the
    /// removal for the cap only; then the hub goes all the same.
    func testAnUnlinkWhoseFarewellNeverLeavesStillRemovesTheHub() async throws {
        farewellStuck = true
        farewellCap = .milliseconds(200)
        let root = try makeRoot(links: [linkRecord()])
        await root.env.waitForBoot()

        await root.linking.unlink(TestHub.acme)

        XCTAssertGreaterThan(farewellChecks.count, 1, "it asked again while the record waited")
        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false], "the removal finished")
        XCTAssertNil(try registry.row(TestHub.acme))
        XCTAssertTrue(root.showsOnboarding)
        XCTAssertEqual(root.linking.phase, .idle)
    }

    /// #143: an `unlinked` record still queued at the cap is kept, sealed,
    /// in the registry while the hub's files go; a resend that fails keeps
    /// it for the next try, one that goes out clears it.
    func testAFarewellStillQueuedAtTheCapIsKeptAcrossTheWipeUntilAResendGoesOut() async throws {
        farewellStuck = true
        farewellCap = .milliseconds(200)
        let root = try makeRoot(links: [linkRecord()])
        await root.env.waitForBoot()

        await root.linking.unlink(TestHub.acme)

        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false], "the replica is wiped all the same")
        let kept = try XCTUnwrap(try registry.pendingFarewells().first, "the farewell outlives the replica")
        let queued = try XCTUnwrap(farewellChecks.last?.record)
        XCTAssertEqual(kept.hubID, TestHub.acme)
        XCTAssertEqual(kept.scope, .private)
        XCTAssertEqual(kept.userRecordName, "_owner-acme")
        XCTAssertEqual(kept.record.recordName, queued.recordName, "the sealed record the queue held")
        XCTAssertEqual(kept.record.payload, queued.payload)
        XCTAssertEqual(kept.record.kind, WireKind.envelope)

        await root.linking.retryFarewells()

        XCTAssertEqual(farewellResends.map(\.hubID), [TestHub.acme])
        XCTAssertEqual(try registry.pendingFarewells().map(\.hubID), [TestHub.acme], "a failed resend keeps it")

        farewellResendSucceeds = true
        await root.linking.retryFarewells()

        XCTAssertEqual(farewellResends.count, 2)
        XCTAssertTrue(try registry.pendingFarewells().isEmpty, "sent: no longer kept")
    }

    /// #143: a farewell that went out is not kept; a new link to a hub
    /// whose farewell was kept drops it unsent.
    func testASentFarewellIsNotKeptAndARelinkDropsAKeptOne() async throws {
        let root = try makeRoot(links: [linkRecord()])
        await root.env.waitForBoot()
        await root.linking.unlink(TestHub.acme)
        XCTAssertTrue(try registry.pendingFarewells().isEmpty, "it left the queue")

        let sealed = CloudRecord(recordName: "wire", zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: Data([1]))
        try registry.savePendingFarewell(PendingFarewell(
            hubID: TestHub.acme, scope: .private, userRecordName: "_owner-acme", record: sealed, since: Date()
        ))
        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: true)
        try await root.linked(linkRecord(), device: device)

        XCTAssertTrue(try registry.pendingFarewells().isEmpty)
        await root.linking.retryFarewells()
        XCTAssertTrue(farewellResends.isEmpty, "never sent over the new link")
    }

    /// Fix round 2: the cap bounds the whole wait, a send that never
    /// returns included; the removal goes on at once.
    func testAnUnlinkWhoseSendHangsStillRemovesTheHubWithinTheCap() async throws {
        farewellSendHangs = true
        farewellCap = .milliseconds(200)
        addTeardownBlock { @MainActor in
            self.hungSends.forEach { $0.resume() }
            self.hungSends = []
        }
        let root = try makeRoot(links: [linkRecord()])
        await root.env.waitForBoot()
        let started = ContinuousClock.now

        await root.linking.unlink(TestHub.acme)

        XCTAssertLessThan(started.duration(to: .now), .seconds(3), "the cap, not the hung send, ended the wait")
        XCTAssertEqual(hungSends.count, 1, "the send was still hanging when the removal went on")
        XCTAssertTrue(farewellChecks.isEmpty, "it never returned to look at the queue")
        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false], "the removal finished")
        XCTAssertNil(try registry.row(TestHub.acme))
        XCTAssertEqual(root.linking.phase, .idle)
    }

    /// Fix round 1, I2: a removal of an id that names no directory touches
    /// no path.
    func testARemovalOfAnUnusableHubIDTouchesNoPath() async throws {
        let root = try makeRoot(links: [linkRecord()])

        let wipe = await root.removeHub("../hub-acme", keepRecordings: true, farewell: nil)

        XCTAssertEqual(wipe, LocalWipe())
        XCTAssertEqual(hubFilesExist(TestHub.acme), [true, true, true])
        XCTAssertNotNil(try registry.row(TestHub.acme))
    }

    /// A hub the Mac removed is forgotten with no farewell.
    func testForgettingAFrozenHubSendsNoFarewell() async throws {
        let root = try makeRoot(links: [linkRecord()], frozen: [TestHub.acme])

        await root.linking.forget(TestHub.acme)

        XCTAssertTrue(farewellChecks.isEmpty)
        XCTAssertNil(try registry.row(TestHub.acme))
    }

    // MARK: - The Mac's removal (spec §6.1, Review Focus 4)

    func testRemovalOfAnInactiveHubFreezesOnlyThatHub() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)
        let hubA = try session(root, TestHub.acme)
        let hubB = try session(root, TestHub.home)
        await root.env.waitForBoot()
        try await poll { hubA.isLooping && hubB.isLooping }

        hubB.onLinkSignal?(.unlinked)

        // The notice lands last, once the freeze (its outbox, uploader and
        // recorder hand-off) has returned: wait for the whole removal, not
        // for its first visible step.
        try await poll { root.linking.notice != nil }
        XCTAssertEqual(root.linking.notice, .removed(macName: "Home Mac"))
        XCTAssertEqual(try registry.row(TestHub.home)?.state, .unlinkedByMac)
        XCTAssertFalse(hubB.writesAllowed, "the removed hub sends nothing")
        XCTAssertFalse(hubB.isLooping, "the removed hub stops syncing")
        XCTAssertEqual(hubB.linkedDevice, device, "its link stands, read-only")
        do {
            try await hubB.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
            XCTFail("a frozen hub sends nothing")
        } catch {
            XCTAssertEqual(error as? ActionOutboxError, .notLinked)
        }
        XCTAssertTrue(root.env.session(TestHub.home) === hubB, "its data stays readable until Forget")
        XCTAssertTrue(hubA.isLooping, "the other hub keeps syncing")
        XCTAssertEqual(root.env.activeHubID, TestHub.acme)
        XCTAssertEqual(try registry.row(TestHub.acme)?.state, .linked)
        try await hubA.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-2")
        XCTAssertEqual(root.linking.notice, .removed(macName: "Home Mac"))
        XCTAssertEqual(hubFilesExist(TestHub.home), [true, true, true], "nothing is wiped")
    }

    /// Ruling 4: a row in `unlinked_by_mac` booted from the registry ends as
    /// a hub frozen live does: the same device kept, writes off, no sync,
    /// the replica readable.
    func testAFrozenBootEndsAsALiveFreezeDoes() async throws {
        let live = try makeRoot(links: [linkRecord()])
        let liveSession = try session(live, TestHub.acme)
        await live.env.waitForBoot()
        await live.markRemovedByMac(TestHub.acme)

        let booted = try makeRoot(links: [linkRecord()], frozen: [TestHub.acme])
        let bootedSession = try session(booted, TestHub.acme)
        try await poll { !bootedSession.writesAllowed && bootedSession.linkedDevice != nil }

        for (name, frozen) in [("live", liveSession), ("boot", bootedSession)] {
            XCTAssertEqual(frozen.linkedDevice, device, name)
            XCTAssertFalse(frozen.writesAllowed, name)
            XCTAssertFalse(frozen.isLooping, name)
            XCTAssertNil(frozen.deviceSettings.linkedDevice, name)
            XCTAssertNoThrow(try sliceCount(frozen), name)
            do {
                try await frozen.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
                XCTFail("\(name): a frozen hub sends nothing")
            } catch {
                XCTAssertEqual(error as? ActionOutboxError, .notLinked, name)
            }
        }
        XCTAssertEqual(try registry.row(TestHub.acme)?.state, .unlinkedByMac)
    }

    func testTheTransportsUnlinkedSignalFreezesTheHub() async throws {
        let root = try makeRoot(links: [linkRecord()])
        let first = root.env.activeSession
        XCTAssertFalse(root.showsOnboarding)

        first.onLinkSignal?(.unlinked)

        try await poll { root.linking.notice == .removed(macName: "Acme Mac") }
        try await poll { !first.writesAllowed }
        XCTAssertEqual(root.linking.links.first?.state, .unlinkedByMac)
        XCTAssertTrue(root.env.activeSession === first, "kept, read-only")
        XCTAssertFalse(root.showsOnboarding, "a frozen hub still shows its data")
    }

    func testAnAccountChangeSignalForAnotherAccountEndsTheLink() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")])
        let first = root.env.activeSession
        container.userRecordNameValue = "_colleague-b"

        first.onLinkSignal?(.accountChanged)

        try await poll { root.linking.links.isEmpty && root.env.sessions.isEmpty }
        XCTAssertNil(root.linking.notice)
        XCTAssertTrue(try registry.rows().isEmpty, "spec §6.2: the registry is wiped")
        XCTAssertTrue(root.showsOnboarding)
        XCTAssertEqual(hubFilesExist(TestHub.acme) + hubFilesExist(TestHub.home), Array(repeating: false, count: 6))
    }

    /// Ruling 8: a removal, a freeze and the account-change wipe each run
    /// inside background work, so a push that found them finishes them.
    func testRemovalsFreezesAndTheAccountWipeRunInsideBackgroundWork() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac"), linkRecord(TestHub.studio)])

        _ = await root.removeHub(TestHub.studio, keepRecordings: true, farewell: nil)
        XCTAssertEqual(workBegun, ["hub-remove"])
        XCTAssertEqual(workEnded, ["hub-remove"])

        await root.markRemovedByMac(TestHub.home)
        XCTAssertEqual(workBegun.count, 2)
        XCTAssertEqual(workEnded.count, 2)

        container.userRecordNameValue = "_colleague-b"
        root.env.activeSession.onLinkSignal?(.accountChanged)
        try await poll { root.env.sessions.isEmpty && self.workEnded.count == self.workBegun.count && self.workBegun.count > 2 }
        XCTAssertEqual(Set(workBegun), ["hub-remove"])
    }

    // MARK: - The grant check per hub (#64)

    /// One fetch of `hubID`'s session and its link check, awaited.
    private func fetch(_ root: AppRoot, _ hubID: String) async throws {
        let target = try session(root, hubID)
        await target.refresh(.pull)
        await root.linkChecks[hubID]?.value
    }

    func testTheGrantRemovalCheckReadsEachHubsOwnGrant() async throws {
        let linkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = FakeLinkClock(now: linkedAt)
        let root = try makeRoot(
            links: [linkRecord(linkedAt: linkedAt), linkRecord(TestHub.home, macName: "Home Mac", linkedAt: linkedAt)],
            active: TestHub.acme,
            linkClock: clock
        )
        // Booted before the Mac's records land: no launch fetch reads half
        // of them.
        await root.env.waitForBoot()
        let later = linkedAt.addingTimeInterval(60)
        let homeGrant = DeviceGrant(
            deviceID: device.deviceID, hubID: TestHub.home, name: device.name, scope: .private,
            linked: true, linkedAt: linkedAt, typingAllowed: false, startSessionsAllowed: true
        )
        try await TestHub.hub(over: transport(TestHub.home), TestHub.home).save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: later, hubID: TestHub.home, macName: "Home Mac"), modifiedAt: later),
            try TestPhone.grantRecord(homeGrant, keys: TestPhone.keyboxKeys(), modifiedAt: later)
        ])
        // hub-acme's replica holds its heartbeat and no grant at all: its
        // own check would read a removal, but only hub-home is fetched.
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: later), modifiedAt: later)])

        try await fetch(root, TestHub.home)
        XCTAssertNil(try registry.row(TestHub.home)?.grantMissingSince, "granted in its own replica")

        try await TestHub.hub(over: transport(TestHub.home), TestHub.home).delete(recordNames: [homeGrant.recordName], in: .data)
        try await fetch(root, TestHub.home)
        XCTAssertEqual(try registry.row(TestHub.home)?.grantMissingSince, linkedAt, "the first look, on hub-home's row")
        XCTAssertNil(try registry.row(TestHub.acme)?.grantMissingSince)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        try await fetch(root, TestHub.home)

        XCTAssertEqual(try registry.row(TestHub.home)?.state, .unlinkedByMac)
        XCTAssertEqual(try registry.row(TestHub.acme)?.state, .linked, "the active hub is untouched")
        XCTAssertEqual(root.env.activeHubID, TestHub.acme)
        XCTAssertEqual(root.linking.notice, .removed(macName: "Home Mac"))
    }

    /// #64: a same-Apple-ID phone gets no `unlinked` event. After each
    /// fetch the root judges the grant of the device id the link was made
    /// with: one this build cannot decode is never judged, and a grant gone
    /// on two fetches 30 s apart is the Mac's Remove.
    func testTheLinkedDevicesGrantGoneOnTwoFetchesIsTheMacsRemoveAndAnUndecodableOneIsNot() async throws {
        let linkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = FakeLinkClock(now: linkedAt)
        let root = try makeRoot(links: [linkRecord(linkedAt: linkedAt)], linkClock: clock)
        await root.env.waitForBoot()
        // E2E: the grant is this phone's sealed keybox (the replica keeps only this phone's own, F13).
        let transport = TestHub.hub(over: try transport(TestHub.acme), TestHub.acme)
        let later = linkedAt.addingTimeInterval(60)
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: TestHub.acme, name: device.name, scope: .private,
            linked: true, linkedAt: linkedAt, typingAllowed: false, startSessionsAllowed: true
        )
        try await transport.save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: later), modifiedAt: later),
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(), modifiedAt: later)
        ])
        let linked = { (try? self.registry.row(TestHub.acme))?.state == .linked }
        try await fetch(root, TestHub.acme)
        XCTAssertTrue(linked(), "granted under the id it linked with")

        let reshaped = CloudRecord(
            recordName: grant.recordName, zone: .data, kind: SliceKind.deviceGrant.rawValue,
            modifiedAt: later.addingTimeInterval(1), payload: Data(#"{"linked":"maybe"}"#.utf8)
        )
        try await transport.save([reshaped])
        try await fetch(root, TestHub.acme)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        try await fetch(root, TestHub.acme)
        XCTAssertTrue(linked(), "an unreadable keybox is not a removed one")

        try await transport.delete(recordNames: [grant.recordName], in: .data)
        try await fetch(root, TestHub.acme)
        XCTAssertTrue(linked(), "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        try await fetch(root, TestHub.acme)
        XCTAssertEqual(root.linking.links.first?.state, .unlinkedByMac, "the Mac's Remove freezes the hub")
        XCTAssertEqual(root.linking.notice, .removed(macName: "Acme Mac"))
    }

    /// Every fetch notes the hub's heartbeat on its row (the list's flavor
    /// and offline days read it).
    func testAFetchedHeartbeatIsNotedOnItsHubsRow() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")])
        await root.env.waitForBoot()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try await TestHub.hub(over: transport(TestHub.home), TestHub.home).save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: now, hubID: TestHub.home, macName: "Home Mac", flavor: .corp), modifiedAt: now)
        ])

        try await fetch(root, TestHub.home)

        let row = try XCTUnwrap(try registry.row(TestHub.home))
        XCTAssertEqual(row.flavor, "corp")
        XCTAssertEqual(row.lastHeartbeatAt, now)
        XCTAssertNil(try registry.row(TestHub.acme)?.lastHeartbeatAt, "only the fetched hub's row")
    }

    // MARK: - Transport store location (0xdead10cc)

    /// Two throwaway directories: the app group's and the app's own.
    private func makeStoreDirectories() throws -> (group: URL, own: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transport-move-\(UUID().uuidString)")
        let group = root.appendingPathComponent("group", isDirectory: true)
        let own = root.appendingPathComponent("own", isDirectory: true)
        for dir in [group, own] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (group, own)
    }

    /// An earlier build's store in the app group moves into the app's own
    /// directory once, with its SQLite side files, and opens there with its
    /// rows; a second launch finds it in place.
    func testTheTransportStoreMovesOutOfTheAppGroupOnce() async throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let oldPath = group.appendingPathComponent(name).path
        _ = try TransportStore(path: oldPath)
        try await DatabaseQueue(path: oldPath).write { db in
            try db.execute(sql: "INSERT INTO engine_state (id, data) VALUES (1, x'2a')")
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data(suffix.utf8).write(to: group.appendingPathComponent(name + suffix))
        }

        let path = AppEnvironment.moveTransportStore(from: group, to: own)

        XCTAssertEqual(path, own.appendingPathComponent(name).path)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath + suffix), "\(suffix) left in the app group")
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + suffix)), Data(suffix.utf8))
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            // The stand-in side files are not SQLite's: drop them before opening.
            try FileManager.default.removeItem(atPath: path + suffix)
        }
        let engineState = try await DatabaseQueue(path: path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM engine_state") ?? 0
        }
        XCTAssertEqual(engineState, 1, "the rows came along")

        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: own), path, "the next launch finds it in place")
    }

    /// A fresh install has nothing to move; a store already in the app's own
    /// directory wins over a stray one in the app group, which is left alone.
    func testTheTransportStoreMoveLeavesAnInstalledStoreAlone() throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let ownPath = own.appendingPathComponent(name).path
        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: own), ownPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownPath), "nothing is created")

        try Data("own".utf8).write(to: URL(fileURLWithPath: ownPath))
        let stray = group.appendingPathComponent(name)
        try Data("stray".utf8).write(to: stray)
        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: own), ownPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ownPath)), Data("own".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    /// The live path resolves once per process: a move that failed keeps
    /// the app-group store open there, and a later resolution (a restart's
    /// environment, the wipe) returns that same path instead of moving the
    /// store from under the open database.
    func testTheTransportStorePathResolvesOncePerProcess() throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let oldMain = group.appendingPathComponent(name)
        try Data("main".utf8).write(to: oldMain)
        let target = OSAllocatedUnfairLock(initialState: own.appendingPathComponent("gone", isDirectory: true))
        let resolver = TransportStorePathResolver { AppEnvironment.moveTransportStore(from: group, to: target.withLock { $0 }) }

        XCTAssertEqual(try resolver.path(), oldMain.path, "the failed move keeps the old store")
        target.withLock { $0 = own }
        XCTAssertEqual(try resolver.path(), oldMain.path, "the same path, no second move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldMain.path), "the open store stays where it is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.appendingPathComponent(name).path))
    }

    /// A move that fails keeps the app-group store, side files included,
    /// and opens it there for this launch.
    func testAFailedTransportStoreMoveKeepsTheOldStore() throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let oldMain = group.appendingPathComponent(name)
        try Data("main".utf8).write(to: oldMain)
        try Data("wal".utf8).write(to: group.appendingPathComponent(name + "-wal"))
        let missing = own.appendingPathComponent("gone", isDirectory: true)

        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: missing), oldMain.path)
        XCTAssertEqual(try Data(contentsOf: oldMain), Data("main".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldMain.path + "-wal"))
    }

    private func transportCounts(_ raw: DatabaseQueue) async throws -> (pending: Int, events: Int, engineState: Int) {
        try await raw.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM engine_state") ?? 0
            )
        }
    }

    /// Board #70: an unlink's flush waits for the engine start only, never
    /// for the first fetch, which a slow network can hold.
    func testSendNowDoesNotWaitForTheFirstFetch() async throws {
        let gate = GatedTransport()
        let env = try HubSession(
            transport: gate,
            replicaPath: try makeReplicaPath(),
            transportKind: .cloudKit,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in
            env.stop()
            await gate.open()
        }
        var sent = false
        let flush = Task { @MainActor in
            await env.sendNow()
            sent = true
        }
        try await poll { sent }
        XCTAssertFalse(env.isBootstrapped, "the first fetch is still held")
        await flush.value
    }

    // MARK: - Prepare: one session per scanned hub

    func testPreparingAnotherScopeRebuildsTheCandidateOnAnEmptyReplica() async throws {
        let root = try makeRoot()
        let candidate = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        let first = try session(root, TestHub.acme)
        XCTAssertTrue((candidate as? SecureTransport) === (first.linkTransport as? SecureTransport), "the session's sealed transport")
        XCTAssertNil(root.env.activeHubID, "a candidate is not on screen")
        XCTAssertTrue(root.showsOnboarding, "and not a link")
        let now = Date()
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // Nothing pushes here and the launch fetch may have ended before the
        // save: a fetch begun after it brings the record in.
        await first.waitForBoot()
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCount(first)) == 1 }

        let samePrivate = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        XCTAssertTrue(root.env.session(TestHub.acme) === first, "the running scope needs no new session")
        XCTAssertTrue((samePrivate as? SecureTransport) === (first.linkTransport as? SecureTransport))

        let shared = try await root.prepare(scope: .shared(ownerName: "_owner-acme"), hubID: TestHub.acme, fresh: false)

        let second = try session(root, TestHub.acme)
        XCTAssertFalse(second === first)
        XCTAssertFalse(first.isLooping, "the other scope's session is shut down")
        XCTAssertEqual(built.last?.scope, .shared(ownerName: "_owner-acme"))
        XCTAssertTrue((shared as? SecureTransport) === (second.linkTransport as? SecureTransport), "the new session's")
        XCTAssertEqual(try sliceCount(second), 0, "another database's data is not kept")
        XCTAssertEqual(built.count, 2)
    }

    func testPreparingAnotherHubAddsItsOwnSessionOnItsOwnReplica() async throws {
        let root = try makeRoot()
        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        let acme = try session(root, TestHub.acme)
        let now = Date()
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // Nothing pushes here and the launch fetch may have ended before the
        // save: a fetch begun after it brings the record in.
        await acme.waitForBoot()
        _ = await acme.refresh(.pull)
        try await poll { (try? self.sliceCount(acme)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: TestHub.home, fresh: false)

        let home = try session(root, TestHub.home)
        XCTAssertFalse(home === acme, "another hub is another pair of zones")
        XCTAssertEqual(try sliceCount(home), 0, "another hub's data is not shared")
        XCTAssertTrue(root.env.session(TestHub.acme) === acme, "the first one is left alone")
        XCTAssertEqual(try sliceCount(acme), 1)
        _ = try await root.prepare(scope: .private, hubID: TestHub.home, fresh: false)
        XCTAssertEqual(built.count, 2, "the running hub needs no new session")
    }

    /// A rescan of a hub the Mac removed starts it again from empty files.
    func testPreparingAFrozenHubRemovesItFirst() async throws {
        let root = try makeRoot(links: [linkRecord()], frozen: [TestHub.acme])
        let frozen = try session(root, TestHub.acme)

        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)

        XCTAssertFalse(root.env.session(TestHub.acme) === frozen)
        XCTAssertNil(try registry.row(TestHub.acme), "removed first, with its recordings held")
        XCTAssertEqual(built.count, 2)
    }

    func testFetchKeyboxReadsThisPhonesHydratedKeyboxOfThatHub() async throws {
        let root = try makeRoot()
        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        // The boot's own first fetch done: a fetch coalesced into it would not see the save below.
        try await poll { (try? self.session(root, TestHub.acme))?.isBootstrapped == true }
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: TestHub.acme, name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        let keys = TestPhone.keyboxKeys(epoch: 1)
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save([try TestPhone.grantRecord(grant, keys: keys, modifiedAt: Date())])

        let fetched = await root.fetchKeybox(hubID: TestHub.acme, deviceID: device.deviceID)

        XCTAssertEqual(fetched, Keybox(grant: grant, keys: keys), "the grant and the epoch keys")
        let other = await root.fetchKeybox(hubID: TestHub.acme, deviceID: UUID().uuidString)
        XCTAssertNil(other)
        let noSession = await root.fetchKeybox(hubID: TestHub.home, deviceID: device.deviceID)
        XCTAssertNil(noSession)
    }

    /// A Workbench choice made before linking reaches the Mac with the link
    /// record, and becomes the hub's own once the link completes; the next
    /// link starts from the defaults. Ruling 5: a candidate (or an orphan's
    /// session) reads it without using it up.
    func testAChoiceMadeBeforeLinkingTravelsWithTheLinkRecord() async throws {
        let root = try makeRoot()
        let unlinked = DeviceSettings(transport: try TestPhone.transport(), defaults: defaults, hubID: DeviceSettings.unlinkedHubID)
        await unlinked.setTypingRequested(true)
        await unlinked.setStartSessions(false)
        try paths.prepare(TestHub.orphan)
        try await HubBoot.removeOrphans(registry: registry, paths: paths, keeping: nil, factory: try makeFactory())

        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        let payload = root.devicePayload(hubID: TestHub.acme, for: device, linkNonce: "nonce-acme", unlinked: false, now: Date())

        XCTAssertTrue(payload.typingRequested)
        XCTAssertFalse(payload.startSessions)
        XCTAssertNotNil(defaults.object(forKey: "hub.unlinked.device.typingRequested"), "the orphan and the candidate left it")

        try await root.linked(linkRecord(), device: device)
        XCTAssertEqual(defaults.object(forKey: "hub.\(TestHub.acme).device.typingRequested") as? Bool, true, "the hub's own now")
        XCTAssertEqual(defaults.object(forKey: "hub.\(TestHub.acme).device.startSessions") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "hub.unlinked.device.typingRequested"), "used up by the link")

        _ = try await root.prepare(scope: .private, hubID: TestHub.home, fresh: false)
        let next = root.devicePayload(hubID: TestHub.home, for: device, linkNonce: "nonce-home", unlinked: false, now: Date())
        XCTAssertFalse(next.typingRequested, "the unlinked choice went to the first link only")
        XCTAssertTrue(next.startSessions)
    }

    /// A completed link adds the row, turns the session's writes on and
    /// puts it on screen.
    func testLinkedAddsTheRowAndActivatesTheHub() async throws {
        let root = try makeRoot(links: [linkRecord()])
        _ = try await root.prepare(scope: .private, hubID: TestHub.home, fresh: false)
        let home = try session(root, TestHub.home)
        XCTAssertNil(home.linkedDevice)

        try await root.linked(linkRecord(TestHub.home, macName: "Home Mac"), device: device)

        XCTAssertEqual(try registry.rows().map(\.hubID), [TestHub.acme, TestHub.home])
        XCTAssertEqual(root.env.activeHubID, TestHub.home)
        XCTAssertEqual(try registry.activeHubID, TestHub.home)
        XCTAssertEqual(home.linkedDevice, device)
        XCTAssertTrue(home.writesAllowed)
        try await home.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
    }

    /// A fifth hub that got past the scan's check (a race) is refused by
    /// the registry.
    func testLinkedRefusesAFifthHub() async throws {
        let root = try makeRoot(links: (1...HubRegistry.limit).map { linkRecord("hub-\($0)") })
        _ = try await root.prepare(scope: .private, hubID: TestHub.fifth, fresh: false)

        do {
            try await root.linked(linkRecord(TestHub.fifth), device: device)
            XCTFail("a fifth hub must be refused")
        } catch {
            XCTAssertTrue(error is HubRegistryError)
        }
        XCTAssertEqual(try registry.rows().count, HubRegistry.limit)
        XCTAssertNotEqual(root.env.activeHubID, TestHub.fifth)
    }

    // MARK: - Recordings across a removal (board #63)

    private var hold: RecordingHold {
        RecordingHold(directory: paths.holdDirectory)
    }

    /// A voice note of `seconds`, saved (`waiting`) in the active session;
    /// returns its ledger id.
    private func saveVoiceNote(_ root: AppRoot, seconds: TimeInterval = 12) async throws -> String {
        await root.env.recorder.recordVoiceNote()
        clock.advance(seconds)
        await root.env.recorder.stop()
        return try XCTUnwrap(root.env.recorder.savedRecording?.id)
    }

    /// An unlink or a removal during a meeting capture: the capture is
    /// stopped and saved, held for its hub, listed as waiting for that Mac,
    /// and sent only once this phone is linked to that hub again.
    func testARemovalDuringACaptureHoldsItForItsHubAndSendsItAfterRelinkingThatHub() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)
        let first = root.env.activeSession
        try await poll { first.isBootstrapped }
        let event = MeetingEvent(id: "event-1", title: "Design sync", start: clock.now, end: clock.now.addingTimeInterval(1_800))
        await first.recorder.recordMeeting(event)
        XCTAssertTrue(first.recorder.isCapturing)
        clock.advance(30)
        first.recorder.markMoment()

        let wipe = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        XCTAssertEqual(wipe, LocalWipe(notSent: 0, stoppedRecording: true), "held, so not reported Not sent")
        XCTAssertEqual(engine.finishCount, 1, "the file was finalised, not cut off")
        XCTAssertEqual(root.env.activeHubID, TestHub.home)
        try await poll { root.env.activeSession.isBootstrapped }
        XCTAssertTrue(try root.env.store.phoneRecordings().isEmpty, "another hub does not adopt it")
        let held = try XCTUnwrap(root.env.heldRecordings.first, "listed as waiting for its Mac")
        XCTAssertEqual(held.hubID, TestHub.acme)
        XCTAssertEqual(held.marks, [30])
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: paths.recordingsDirectory(TestHub.acme)))
        let list = RecordingsListModel(
            recordings: PhoneRecordingsSnapshot(), replica: CalendarReplicaSnapshot(),
            seen: RecordingsSeen(baseline: .distantPast, opened: []), now: clock.now, calendar: .current,
            held: root.env.heldRecordings
        )
        XCTAssertEqual(list.inProgress.map(\.state), [.heldForMac(nil)])

        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        try await root.linked(linkRecord(), device: device)

        XCTAssertEqual(root.env.activeHubID, TestHub.acme)
        let row = try XCTUnwrap(try root.env.store.phoneRecordings().first)
        XCTAssertEqual(row.id, held.id)
        XCTAssertEqual(row.durationSec, 30)
        XCTAssertEqual(row.eventID, "event-1")
        XCTAssertEqual(try root.env.store.phoneRecordingMarks(id: row.id), [30])
        XCTAssertTrue(root.env.heldRecordings.isEmpty)
        XCTAssertTrue(try hold.load().isEmpty, "adopted, out of the hold")
        let uploads = try await relayUploads(in: try transport(TestHub.acme), hub: TestHub.acme)
        XCTAssertEqual(uploads.map(\.id), [row.id], "sent after relinking its Mac")
    }

    /// Multi-hub spec §5.4: the recorder names the Mac a capture is for as
    /// the switcher does, from the registry at boot and after each link.
    func testTheRootNamesEachHubFromTheRegistry() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")])
        XCTAssertEqual(try session(root, TestHub.acme).hubName, "Acme Mac")
        XCTAssertEqual(try session(root, TestHub.home).hubName, "Home Mac")
        await root.env.waitForBoot()

        _ = try await root.prepare(scope: .private, hubID: TestHub.work, fresh: false)
        try await root.linked(linkRecord(TestHub.work, macName: "Acme Mac"), device: device)

        XCTAssertEqual(try session(root, TestHub.acme).hubName, "Acme Mac · \(TestHub.acme.prefix(4))")
        XCTAssertEqual(try session(root, TestHub.work).hubName, "Acme Mac · \(TestHub.work.prefix(4))")
        XCTAssertEqual(try session(root, TestHub.home).hubName, "Home Mac")
    }

    /// Review F6: a recording held for one Mac never goes to another.
    func testAnotherHubNeverReceivesAHeldRecording() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        _ = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        _ = try await root.prepare(scope: .private, hubID: TestHub.studio, fresh: false)
        try await root.linked(linkRecord(TestHub.studio, macName: "Acme Studio"), device: device)

        let uploads = try await relayUploads(in: try transport(TestHub.studio), hub: TestHub.studio)
        XCTAssertTrue(uploads.isEmpty, "the other Mac gets nothing")
        XCTAssertTrue(try root.env.store.phoneRecordings().isEmpty)
        XCTAssertEqual(root.env.heldRecordings.map(\.id), [id], "still waiting for its own Mac")
    }

    /// Review F6: an iCloud account change carries nothing: the recordings
    /// were made for the old account's Mac, and are reported Not sent.
    func testAnAccountChangeRemovalCarriesNoRecording() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let file = try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: paths.recordingsDirectory(TestHub.acme))

        let wipe = await root.removeHub(TestHub.acme, keepRecordings: false, farewell: nil)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        XCTAssertTrue(try hold.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "deleted with the hub's folder")
    }

    /// Verify round: killed after the hold and before the replica went (or
    /// a replica that could not be removed): the next boot finds the row
    /// still in the replica, brings the audio back next to it, and sends it
    /// — its `uploading` row as the relaunch retry (board #724): in the
    /// foreground, with the Mac online and the backoff due.
    func testKilledAfterHoldingBeforeTheReplicaWentRestoresTheAudio() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let recordings = paths.recordingsDirectory(TestHub.acme)
        let row = try XCTUnwrap(try root.env.store.phoneRecording(id: id))
        let file = row.fileURL(in: recordings)
        try hold.hold([HeldRecording(row, marks: [], hubID: TestHub.acme, macName: nil)], from: recordings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the audio is in the hold")
        root.env.activeSession.stop()

        // The relaunch: the same replica, the same hub, past the first
        // backoff step, with the Mac's heartbeat fresh.
        let relaunchAt = Date().addingTimeInterval(RecordingUploader.retryDelays[0] + 1)
        let transport = InMemoryCloudTransport()
        try await TestPhone.hub(over: transport).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: relaunchAt), modifiedAt: relaunchAt)])
        let relaunched = try HubSession(
            transport: transport,
            replicaPath: paths.replicaPath(TestHub.acme),
            transportKind: .cloudKit,
            hubID: TestHub.acme,
            linkedDevice: device,
            keys: try TestPhone.keys(),
            defaults: try makeDefaults(),
            recordingsDirectory: recordings,
            hold: hold,
            uploadRetriesAllowed: true,
            makeRecorder: { [engine, clock] uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil
                )
            },
            now: { relaunchAt }
        )
        addTeardownBlock { @MainActor in relaunched.stop() }
        try await poll { relaunched.isBootstrapped }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "back next to its row, past the sweep")
        XCTAssertTrue(try hold.load().isEmpty)
        XCTAssertEqual(try relaunched.store.phoneRecordings().map(\.id), [id])
        let uploads = try await relayUploads(in: transport)
        XCTAssertEqual(uploads.map(\.id), [id])
    }

    /// Review F1: a capture cut short by an earlier kill, still `recording`
    /// because no launch recovery reached it, keeps its audio: the
    /// hand-over finalizes it from its file and holds it.
    func testACaptureLeftForLaunchRecoveryIsFinalizedAndHeld() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let directory = paths.recordingsDirectory(TestHub.acme)
        // Another process's uploader: the capture is not live in this one.
        let earlier = RecordingUploader(transport: try TestPhone.transport(), store: root.env.store, directory: directory)
        let file = directory.appendingPathComponent("cut-short.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: file)
        let stranded = try await earlier.beginCapture(fileURL: file, startedAt: clock.now, titleHint: "Cut short", eventID: nil)
        engine.fileDuration = 20

        let wipe = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        XCTAssertEqual(wipe, LocalWipe(), "not lost")
        let held = try XCTUnwrap(try hold.load().first)
        XCTAssertEqual(held.id, stranded.id)
        XCTAssertEqual(held.durationSec, 20, "finalized from its file")
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: directory))
    }

    /// Review F2: a stop already saving (the owner's tap, the 3-hour cap)
    /// is waited for, then its recording is held; the removal did not stop
    /// it.
    func testARemovalDuringASaveWaitsForItAndHoldsTheRecording() async throws {
        let root = try makeRoot(links: [linkRecord()])
        let first = root.env.activeSession
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(15)
        engine.holdFinish = true
        let ownerStop = Task { await first.recorder.stop() }
        try await poll { first.recorder.phase == .saving && self.engine.finishCount == 1 }

        let removal = Task { await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(root.env.session(TestHub.acme) === first, "the removal waits for the save")
        engine.releaseFinish()
        let wipe = await removal.value
        await ownerStop.value

        XCTAssertEqual(wipe, LocalWipe(), "the owner stopped it: kept, not the removal's news")
        XCTAssertEqual(try hold.load().map(\.durationSec), [15])
    }

    /// Review F3: a ledger the hand-over cannot read never sends the audio
    /// into a deletion: it moves to the hold's `unreadable` folder, and the
    /// removal says so.
    func testAnUnreadableHandOverKeepsTheAudioAndSaysSo() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let file = try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: paths.recordingsDirectory(TestHub.acme))
        // A manifest that cannot be read: holding fails.
        try FileManager.default.createDirectory(
            at: hold.directory.appendingPathComponent("manifest.json"), withIntermediateDirectories: true
        )

        let wipe = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        let problem = try XCTUnwrap(wipe.problem)
        XCTAssertTrue(problem.hasPrefix("Some recordings couldn't be read"), problem)
        let kept = hold.directory.appendingPathComponent("unreadable").appendingPathComponent(file.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "the audio is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try registry.row(TestHub.acme), "the hub is unlinked all the same")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.replicaPath(TestHub.acme)), "its files wait for the next launch's retry")
        if case .recordingsProblem = LinkNotice.after(wipe) {} else {
            XCTFail("the notice reports the problem")
        }
    }

    /// A recording whose audio is already gone cannot be held: it is
    /// reported Not sent, as before.
    func testARecordingWithoutItsFileIsReportedNotSent() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try FileManager.default.removeItem(
            at: try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: paths.recordingsDirectory(TestHub.acme))
        )

        let wipe = await root.removeHub(TestHub.acme, keepRecordings: true, farewell: nil)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        XCTAssertTrue(try hold.load().isEmpty)
    }

    // MARK: - One hub's failure (spec §6.3)

    /// A hub whose session cannot be built leaves the others booting: the
    /// first one that opened goes on screen, the broken one is listed with
    /// its problem, never activated, and Forget removes its row and files.
    func testOneHubsFailedSessionLeavesTheOthersBootingAndCanBeForgotten() async throws {
        failingHubs = [TestHub.acme]
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)

        XCTAssertEqual(root.env.activeHubID, TestHub.home, "the saved active hub would not open: the first that did")
        XCTAssertFalse(root.showsOnboarding)
        XCTAssertNil(root.env.session(TestHub.acme))
        XCTAssertEqual(root.env.unopenedHubIDs, [TestHub.acme])
        try await poll { root.env.activeSession.isLooping }
        let items = root.env.hubListItems(root.linking.links, now: Date())
        let broken = try XCTUnwrap(items.first { $0.id == TestHub.acme }, "listed in the switcher and Settings → Macs")
        XCTAssertTrue(broken.unopened)
        XCTAssertEqual(broken.problem, "Couldn't open this Mac's data on this iPhone")
        XCTAssertEqual(MacsModel.action(for: broken), .forget)
        XCTAssertNil(items.first { $0.id == TestHub.home }?.problem)

        root.env.activate(TestHub.acme)
        XCTAssertEqual(root.env.activeHubID, TestHub.home, "a hub with no session is never put on screen")

        await root.linking.forget(TestHub.acme)

        XCTAssertNil(try registry.row(TestHub.acme))
        XCTAssertTrue(root.env.unopenedHubIDs.isEmpty)
        XCTAssertEqual(hubFilesExist(TestHub.acme), [true, true, true], "nothing deleted: the orphan pass decides")
        XCTAssertEqual(root.linking.links.map(\.hubID), [TestHub.home])
        XCTAssertEqual(root.env.activeHubID, TestHub.home)
    }

    /// Forget of a hub that could not be opened removes its row and its
    /// Settings keys only: its audio stays on disk for the next launch's
    /// orphan pass, which hands it to the hold once a session opens.
    func testForgettingAnUnopenedHubKeepsItsAudioForTheOrphanPass() async throws {
        failingHubs = [TestHub.acme]
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.home)
        let recordings = paths.recordingsDirectory(TestHub.acme)
        let audio = recordings.appendingPathComponent("rec-1.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: audio)
        let uploader = RecordingUploader(
            transport: try TestPhone.transport(), store: try TestPhone.replica(path: paths.replicaPath(TestHub.acme)), directory: recordings
        )
        let now = Date()
        let registered = try await uploader.register(
            fileURL: audio, startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-60), titleHint: "Acme sync"
        )
        let recordingID = try XCTUnwrap(registered).id
        defaults.set(true, forKey: "hub.\(TestHub.acme).device.typingRequested")

        await root.linking.forget(TestHub.acme)

        XCTAssertNil(try registry.row(TestHub.acme), "the row is gone")
        XCTAssertNil(defaults.object(forKey: "hub.\(TestHub.acme).device.typingRequested"), "its Settings keys are gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "its audio is not deleted")
        XCTAssertTrue(try hold.load().isEmpty, "nothing handed over yet")

        failingHubs = []
        try await HubBoot.removeOrphans(registry: registry, paths: paths, keeping: nil, factory: try makeFactory())

        XCTAssertEqual(try hold.load().map(\.id), [recordingID], "the next launch's orphan pass holds it")
        XCTAssertEqual(try hold.load().first?.hubID, TestHub.acme)
        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false], "then its files go")
    }

    /// Every hub failing fails the boot (`BootFailureView`), never Welcome:
    /// the links still exist.
    func testEveryHubFailingFailsTheBoot() throws {
        failingHubs = [TestHub.acme, TestHub.home]

        XCTAssertThrowsError(try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")])) { error in
            guard case .noHubOpened = error as? AppEnvironmentError else {
                return XCTFail("expected noHubOpened, got \(error)")
            }
        }
        XCTAssertEqual(try registry.hubIDs(), [TestHub.acme, TestHub.home], "the links are kept")
    }

    // MARK: - The last hub's removal (the forwarders)

    /// Removing the only hub while its recorder shows a result leaves every
    /// forwarder readable: the views still on screen while the root turns to
    /// Welcome read the removed session, never a trap.
    func testRemovingTheLastHubLeavesEveryForwarderReadable() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        _ = try await saveVoiceNote(root)
        let removed = root.env.activeSession
        XCTAssertNotNil(removed.recorder.savedRecording, "the result is on screen")

        await root.linking.unlink(TestHub.acme)

        let env = root.env
        XCTAssertNil(env.activeHubID)
        XCTAssertTrue(env.sessions.isEmpty)
        XCTAssertTrue(root.showsOnboarding)
        XCTAssertTrue(env.activeSession === removed, "the removed session, until another hub activates")
        XCTAssertTrue(env.store === removed.store)
        XCTAssertTrue(env.outbox === removed.outbox)
        XCTAssertTrue(env.reportRequests === removed.reportRequests)
        XCTAssertTrue(env.boardWriter === removed.boardWriter)
        XCTAssertTrue(env.askDrafts === removed.askDrafts)
        XCTAssertTrue(env.askAnswerer === removed.askAnswerer)
        XCTAssertTrue(env.sessionStarts === removed.sessionStarts)
        XCTAssertTrue(env.sessionInputs === removed.sessionInputs)
        XCTAssertTrue(env.deviceSettings === removed.deviceSettings)
        XCTAssertTrue(env.workbenchReplica === removed.workbenchReplica)
        XCTAssertTrue(env.calendarReplica === removed.calendarReplica)
        XCTAssertTrue(env.phoneRecordings === removed.phoneRecordings)
        XCTAssertTrue(env.recorder === removed.recorder)
        _ = env.workbenchReplica.openAskCount
        _ = env.recorder.isPresented
        _ = env.heldRecordings
        _ = env.linkedDevice
        _ = env.lastSyncAt
        XCTAssertFalse(env.isLooping)
        XCTAssertNil(env.captureHubName)
        _ = env.canStartCapture
        let fetched = await env.refresh(.pull)
        XCTAssertFalse(fetched, "no hub on screen: nothing is fetched")
        await env.sendNow()
        env.recorder.close()

        _ = try await root.prepare(scope: .private, hubID: TestHub.home, fresh: false)
        try await root.linked(linkRecord(TestHub.home, macName: "Home Mac"), device: device)
        XCTAssertEqual(env.activeHubID, TestHub.home)
        XCTAssertTrue(env.activeSession === env.session(TestHub.home), "a new hub on screen ends the retained one")
    }

    // MARK: - The stale notice on a switch

    /// A switch re-evaluates the stale notice for the new hub at once, with
    /// no fetch (`AppEnvironment.onActivate`).
    func testASwitchReevaluatesTheStaleNoticeWithoutAFetch() async throws {
        let root = try makeRoot(links: [linkRecord(), linkRecord(TestHub.home, macName: "Home Mac")], active: TestHub.acme)
        let hubA = try session(root, TestHub.acme)
        await root.env.waitForBoot()
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: Date().addingTimeInterval(-2 * 86_400)), modifiedAt: Date())
        ])
        try await fetch(root, TestHub.acme)
        try await poll { root.linking.notice == .stale(macName: "Acme Mac") }

        root.env.activate(TestHub.home)

        XCTAssertNil(root.linking.notice, "no heartbeat of Home Mac read yet: Acme Mac's notice does not carry over")
        root.env.activate(TestHub.acme)
        XCTAssertEqual(root.linking.notice, .stale(macName: "Acme Mac"), "from its session's last heartbeat")
        XCTAssertNotNil(hubA.heartbeat)
    }

    // MARK: - The demo

    /// A demo root over one demo session, stopped on teardown.
    private func makeDemoRoot() throws -> AppRoot {
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        return try AppRoot.demo(AppEnvironment.single(session, defaults: defaults), defaults: defaults)
    }

    func testALiveRootWithoutALinkOnboardsAndTheDemoNever() throws {
        let live = try makeRoot()
        XCTAssertTrue(live.showsOnboarding)
        XCTAssertTrue(live.env.sessions.isEmpty, "a phone with no link runs no session")

        let demo = try makeDemoRoot()
        XCTAssertFalse(demo.showsOnboarding)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    func testTheDemoIgnoresALinkURL() async throws {
        let demo = try makeDemoRoot()
        let iat = Int64(Date().timeIntervalSince1970)
        let code = LinkPayload(
            hubID: TestHub.acme, macName: "Acme Mac", ownerUser: "_owner-acme", nonce: LinkPayload.makeNonce(), iat: iat, exp: iat + 600,
            hubSigningKey: LinkPayload.makeNonce(), hubAgreementKey: LinkPayload.makeNonce()
        )

        await demo.open(code.url())

        XCTAssertEqual(demo.linking.phase, .idle)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    // MARK: - Glue: the link URL and Unlink (board #71)

    /// The `device` records the phone sealed into `transport`, as the test hub opens them.
    private func deviceWrites(in transport: InMemoryCloudTransport) async throws -> [DevicePayload] {
        let opened = try await TestPhone.hub(over: transport).changes(in: .relay, since: nil).changed
        return try opened
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }

    /// A `watchtower://link` URL on a live root runs the whole flow over the
    /// real host: the code's hub's session, the sealed hello, the Mac's
    /// waiting keybox (the code) and linked keybox (the keys), the row.
    func testALinkURLOnALiveRootLinksThroughTheRealHost() async throws {
        let linkClock = GateLinkClock()
        addTeardownBlock { linkClock.release() }
        let root = try makeRoot(linkClock: linkClock, keyStore: try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity))
        let code = TestPhone.linkCode(iat: Int64(linkClock.start.timeIntervalSince1970))
        let hubID = TestE2E.hubID.uuidString

        let flow = Task { await root.open(code.url()) }
        try await poll { linkClock.waiting == 1 }

        XCTAssertEqual(root.linking.phase, .waiting(macName: "Acme Mac"))
        XCTAssertEqual(built.last?.hubID, hubID, "the code's hub's session")
        XCTAssertEqual(built.last?.scope, .private, "same Apple ID: the private database")
        XCTAssertTrue(root.showsOnboarding, "not linked yet")
        let macSide = try transport(hubID)
        let hellos = try await macSide.changes(in: .relay, since: nil).changed
        XCTAssertEqual(hellos.map(\.recordName), ["hello-\(device.deviceID)"])
        let opened = try TestPhone.openHello(try XCTUnwrap(hellos.first), code: code)
        XCTAssertEqual(opened.hello.device.linkNonce, code.nonce)
        XCTAssertNil(root.linking.linkCode, "SAS v2: no code before the hub's nonce")
        // The Mac accepted the hello: its waiting keybox carries the nonce, and the phone shows the Mac's code.
        let waiting = DeviceGrant(
            deviceID: device.deviceID, hubID: hubID, name: device.name, scope: .private, linked: false,
            typingAllowed: false, startSessionsAllowed: true, awaitingConfirmation: true,
            confirmNonce: TestPhone.confirmNonceText, linkCodeTag: try TestPhone.linkCodeTag(code))
        try await TestPhone.hub(over: macSide).save([try TestPhone.grantRecord(waiting, keys: nil, modifiedAt: Date())])
        linkClock.release()
        try await poll { root.linking.linkCode != nil && linkClock.waiting == 1 }
        XCTAssertEqual(root.linking.linkCode, opened.sas, "the real host's keybox gives the phone the Mac's code")
        XCTAssertTrue(root.linking.macSeesPhone)
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: hubID, name: device.name, scope: .private,
            linked: true, linkedAt: linkClock.start, typingAllowed: false, startSessionsAllowed: true
        )
        try await TestPhone.hub(over: macSide).save([
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(), modifiedAt: Date())
        ])
        linkClock.release()
        // Bounded: a grant that never lands parks the flow on the clock
        // again, which must fail this test, not hang the suite.
        let finished = expectation(description: "the link flow finished")
        Task {
            await flow.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        flow.cancel()

        XCTAssertEqual(root.linking.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(try registry.rows().map(\.hubID), [hubID])
        XCTAssertEqual(root.env.activeHubID, hubID)
        XCTAssertEqual(root.env.linkedDevice?.deviceID, device.deviceID)
        XCTAssertEqual(try keyStore.hubLink(hubID)?.epochs.map(\.epoch), [1], "the keybox's keys are stored")
        XCTAssertFalse(root.showsOnboarding)
    }

    /// Settings → Unlink this Mac on a live root: offered while linked, it
    /// writes `unlinked` to the link's hub and ends on onboarding.
    func testSettingsUnlinkOnALiveRootWritesUnlinkedAndEndsUnlinked() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isLooping }
        let active = root.linking.links.first { $0.hubID == root.env.activeHubID }?.link
        XCTAssertTrue(SettingsView.offersUnlink(transportKind: root.env.transportKind, link: active))
        XCTAssertFalse(SettingsView.offersUnlink(transportKind: .inMemoryDemo, link: linkRecord()), "the demo has no link to end")

        await root.linking.unlink(TestHub.acme)

        XCTAssertTrue(root.linking.links.isEmpty)
        XCTAssertFalse(SettingsView.offersUnlink(transportKind: root.env.transportKind, link: root.linking.links.first?.link))
        try await assertTheFarewellWentThroughTheHubsOwnTransport(TestHub.acme)
        XCTAssertEqual(root.linking.phase, .idle)
        XCTAssertTrue(root.showsOnboarding)
    }

    // MARK: - E2E keys per hub (mobile E2E Tasks 16–17 on HubSession)

    /// The test hub's id: its keys open the replica, and its link's keys are
    /// the ones the link flow keeps or deletes.
    private var e2eHub: String { TestE2E.hubID.uuidString }

    /// D9 under F2: Remove on the Mac publishes this phone's keybox as
    /// revoked; the next fetch reads it and that hub freezes (multi-hub spec
    /// §6.1), its keys kept so its replica stays readable until Forget.
    func testARevokedKeyboxFreezesThatHubAndKeepsItsKeys() async throws {
        let root = try makeRoot(links: [linkRecord(e2eHub), linkRecord(TestHub.home, macName: "Home Mac")], active: e2eHub)
        let hub = try session(root, e2eHub)
        await root.env.waitForBoot()
        let revoked = DeviceGrant(
            deviceID: device.deviceID, hubID: e2eHub, name: device.name, scope: .private,
            linked: false, typingAllowed: false, startSessionsAllowed: true, decidedAt: Date(), revoked: true
        )
        try await TestPhone.hub(over: transport(e2eHub)).save([try TestPhone.grantRecord(revoked, modifiedAt: Date())])

        let fetched = await hub.refresh(.pull)

        XCTAssertTrue(fetched)
        try await poll { (try? self.registry.row(self.e2eHub))?.state == .unlinkedByMac && !hub.writesAllowed }
        try await poll { root.linking.notice == .removed(macName: "Acme Mac") }
        XCTAssertTrue(root.env.session(e2eHub) === hub, "frozen, readable")
        XCTAssertNotNil(try keyStore.hubLink(e2eHub), "its keys stay until Forget")
        XCTAssertEqual(try registry.row(TestHub.home)?.state, .linked, "the other hub is untouched")

        await root.linking.forget(e2eHub)
        XCTAssertNil(try keyStore.hubLink(e2eHub), "Forget deletes them")
    }

    /// A link saved by a pre-E2E build (moved into the registry by the F1
    /// migration) has no hub keys: the launch drops that hub and asks for a
    /// new scan.
    func testALinkWithoutKeysIsDroppedAtLaunchWithTheReScanNotice() async throws {
        withholdKeys = true
        let root = try makeRoot(links: [linkRecord()], keyStore: try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity))
        XCTAssertFalse(root.showsOnboarding)

        await root.resumeLink()

        XCTAssertTrue(root.linking.links.isEmpty)
        XCTAssertEqual(root.linking.notice, .encryptionReScan)
        XCTAssertNil(root.env.session(TestHub.acme))
        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false], "the old link's replica is removed")
        XCTAssertTrue(farewellChecks.isEmpty, "nothing can be sealed for it")
        XCTAssertTrue(root.showsOnboarding)
    }

    /// Port review I-1: a phone upgrading from a build before E2E (F2 on main) may hold a hub whose transport store
    /// is bound and still queues an unacknowledged plaintext save (a recording upload with its plain audio, an
    /// action). That hub has no link keys: its session is built stopped, its engine never starts and its send queue
    /// is wiped before anything could start it; the launch then drops the hub with the re-scan notice.
    func testAPreE2EHubsQueuedPlaintextSaveIsNeverSentAtTheUpgrade() async throws {
        withholdKeys = true
        let queued = CloudRecord(
            recordName: "recupload-1", zone: .relay, kind: RelayRecordKind.recordingUpload.rawValue,
            modifiedAt: Date(), payload: Data(#"{"id":"1","title":"plaintext"}"#.utf8)
        )
        let root = try makeRoot(
            links: [linkRecord()], persistentTransport: true,
            keyStore: try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        ) { paths in
            try paths.prepare(TestHub.acme)
            let path = paths.transportStorePath(TestHub.acme)
            _ = try TransportStore(path: path)
            try DatabaseQueue(path: path).write { db in
                try db.execute(
                    sql: "INSERT INTO pending (record_name, zone, kind, modified_at, payload) VALUES (?, ?, ?, ?, ?)",
                    arguments: [queued.recordName, CloudZoneID.relay.rawValue, queued.kind, 0, queued.payload]
                )
            }
            XCTAssertTrue(try TransportStore(path: path).isPending(recordName: queued.recordName, zone: .relay))
        }
        let hub = try session(root, TestHub.acme)

        XCTAssertFalse(hub.startsEngine, "no link keys: the engine never starts")
        XCTAssertFalse(hub.isLooping, "built stopped, before its boot")
        XCTAssertFalse(
            try TransportStore(path: paths.transportStorePath(TestHub.acme)).isPending(recordName: queued.recordName, zone: .relay),
            "the plaintext save is gone from the send queue"
        )

        await root.resumeLink()

        XCTAssertTrue(root.linking.links.isEmpty)
        XCTAssertEqual(root.linking.notice, .encryptionReScan)
        XCTAssertEqual(hubFilesExist(TestHub.acme), [false, false, false])
    }

    /// F14: a background launch while the phone is locked (after the first
    /// unlock) reads the device id from its `afterFirstUnlock` item, builds
    /// the session and never creates an identity; before the first unlock
    /// the boot waits (#62's guarantee: locked is never "no id").
    func testABackgroundLaunchReadsTheDeviceIDWhileLocked() throws {
        let linked = try TestE2E.phoneStore()
        linked.isLocked = true
        XCTAssertEqual(try DeviceIdentity.current(keys: linked).deviceID, TestE2E.deviceID.uuidString)
        let session = try HubSession(
            transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath(), transportKind: .cloudKit,
            hubID: e2eHub, linkedDevice: device,
            keys: PhoneKeys(store: linked, hubID: e2eHub),
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        XCTAssertTrue(session.hasDeviceKeys)

        let fresh = InMemoryPhoneKeyStore()
        XCTAssertNil(try DeviceIdentity.current(keys: fresh).deviceID)
        let unlinked = try HubSession(
            transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath(), transportKind: .cloudKit,
            hubID: e2eHub, keys: PhoneKeys(store: fresh, hubID: e2eHub),
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in unlinked.stop() }
        XCTAssertFalse(unlinked.hasDeviceKeys)
        XCTAssertNil(try fresh.deviceID(), "no identity is created outside the link flow")

        linked.isBeforeFirstUnlock = true
        XCTAssertThrowsError(try DeviceIdentity.current(keys: linked)) { error in
            XCTAssertEqual(error as? KeyStoreError, .locked)
        }
    }

    func testALockedKeychainAtBootWaitsForTheUnlockAndAnotherFailureShowsIt() {
        let locked = WatchtowerMobileApp.Boot.make(processEnvironment: [:]) { throw KeyStoreError.locked }
        guard case .waitingForUnlock = locked else {
            return XCTFail("a locked Keychain waits for the unlock, got \(locked)")
        }

        let broken = WatchtowerMobileApp.Boot.make(processEnvironment: [:]) { throw KeyStoreError.unexpected(-25_300) }
        guard case let .failed(message) = broken else {
            return XCTFail("another Keychain failure is shown, got \(broken)")
        }
        XCTAssertTrue(message.contains("Keychain"))
    }

    /// The CloudKit kind without device keys seals nothing: no action, no
    /// recording upload, no link record leaves in any form.
    func testTheCloudKitKindWithNoKeysNeverSealsAnything() async throws {
        let transport = InMemoryCloudTransport()
        let session = try HubSession(
            transport: transport, replicaPath: try makeReplicaPath(), transportKind: .cloudKit,
            hubID: e2eHub, linkedDevice: device,
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        XCTAssertFalse(session.hasDeviceKeys)

        do {
            try await session.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
            XCTFail("nothing can be sealed without keys")
        } catch {
            XCTAssertEqual(error as? SecureTransportError, .keysUnavailable)
        }
        do {
            try await session.linkTransport.save([try CloudRecordFactory.record(
                for: session.deviceSettings.devicePayload(for: device, linkNonce: nil, unlinked: true, now: Date()), modifiedAt: Date()
            )])
            XCTFail("the link transport seals too")
        } catch {
            XCTAssertEqual(error as? SecureTransportError, .keysUnavailable)
        }
        let relay = try await transport.changes(in: .relay, since: nil).changed
        XCTAssertTrue(relay.isEmpty, "nothing reached the transport")
    }

    /// F29 per hub: a rescan of a hub this process removed (a re-pair, a
    /// frozen hub scanned again) builds its new session with seqs above the
    /// removed replica's, also across a second removal with no seal between
    /// (the new replica stores the floor at once).
    func testARescanOfARemovedHubCarriesItsSeqCeilingOver() async throws {
        let root = try makeRoot(links: [linkRecord(e2eHub)])
        let first = try session(root, e2eHub)
        try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
        let ceiling = try first.envelopeSeqCeiling()
        XCTAssertGreaterThan(ceiling, 0)

        _ = try await root.prepare(scope: .private, hubID: e2eHub, fresh: true)
        let second = try session(root, e2eHub)
        XCTAssertFalse(second === first, "a new pairing starts on an empty replica")
        XCTAssertNil(try registry.row(e2eHub), "the old link went first")
        XCTAssertGreaterThanOrEqual(try second.envelopeSeqCeiling(), ceiling, "the new replica stores the floor at once")

        _ = await root.removeHub(e2eHub, keepRecordings: true, farewell: nil)
        _ = try await root.prepare(scope: .private, hubID: e2eHub, fresh: true)
        try await root.linked(linkRecord(e2eHub), device: device)
        let third = try session(root, e2eHub)
        try await third.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-2")
        XCTAssertGreaterThan(try third.envelopeSeqCeiling(), ceiling, "seqs continue above the first replica's")
    }

    /// A new pairing (`fresh`) rebuilds even a running session of the same
    /// hub and database on an empty replica.
    func testAFreshPrepareRebuildsTheSessionOnAnEmptyReplica() async throws {
        let root = try makeRoot()
        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: false)
        let first = try session(root, TestHub.acme)
        let now = Date()
        try await TestHub.hub(over: transport(TestHub.acme), TestHub.acme).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // Nothing pushes here and the launch fetch may have ended before the
        // save: a fetch begun after it brings the record in.
        await first.waitForBoot()
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCount(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: TestHub.acme, fresh: true)

        let second = try session(root, TestHub.acme)
        XCTAssertFalse(second === first)
        XCTAssertEqual(try sliceCount(second), 0, "data_seen and the rows go with the replica")
    }

    /// Final review Phone I-1, per hub: a rotation's keybox reached the
    /// replica but its one-shot signal was lost. The next fetch of that hub
    /// reconciles: the missing epoch's keys join the Keychain and the rows
    /// sealed under it open, without a re-scan.
    func testAKeyboxWhoseSignalWasLostIsMergedAfterTheNextFetch() async throws {
        let root = try makeRoot(links: [linkRecord(e2eHub)])
        let hub = try session(root, e2eHub)
        await root.env.waitForBoot()
        hub.onKeyboxChanged = nil
        XCTAssertEqual(try keyStore.hubLink(e2eHub)?.epochs.map(\.epoch), [1])
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: e2eHub, name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        let now = Date()
        let rotated = TestE2E.hubTransport(TestE2E.hub(epoch: 2, firstSeq: 900_000_000_000), inner: try transport(e2eHub))
        try await rotated.save([
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(epoch: 2), modifiedAt: now),
            CloudRecordFactory.record(for: SliceRecord(kind: .workbench, id: "7", modifiedAt: now, payload: Data("{}".utf8)))
        ])

        try await fetch(root, e2eHub)

        XCTAssertEqual(try keyStore.hubLink(e2eHub)?.epochs.map(\.epoch), [1, 2], "merged on the fetch")
        let opened = try await hub.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?", arguments: [SliceKind.workbench.rawValue])
        }
        XCTAssertEqual(opened, 1, "the epoch-2 row opens without waiting for the next hydrate")
    }

    /// M-5: a keybox signed by another hub key than the QR's (an attacker
    /// writing into the zone) is refused at apply through the real host: a
    /// forged "revoked" freezes nothing, and the link flow reads no keybox.
    func testAKeyboxSignedByAStrangerHubKeyIsRefused() async throws {
        let root = try makeRoot(links: [linkRecord(e2eHub)])
        let hub = try session(root, e2eHub)
        await root.env.waitForBoot()
        let forged = DeviceGrant(
            deviceID: device.deviceID, hubID: e2eHub, name: device.name, scope: .private,
            linked: false, typingAllowed: false, startSessionsAllowed: true, decidedAt: Date(), revoked: true
        )
        let stranger = SecureTransport(inner: try transport(e2eHub), keys: StrangerSignedHub(), rollback: InMemoryRollbackGuard())
        try await stranger.save([try TestPhone.grantRecord(forged, modifiedAt: Date())])

        let keybox = await root.fetchKeybox(hubID: e2eHub, deviceID: device.deviceID)

        XCTAssertNil(keybox, "never stored, so never read")
        XCTAssertGreaterThanOrEqual(hub.store.rejectedCount(), 1, "refused at apply: bad signature")
        XCTAssertEqual(try registry.row(e2eHub)?.state, .linked, "nothing frozen")
        XCTAssertEqual(try keyStore.hubLink(e2eHub)?.epochs.map(\.epoch), [1])
    }

    /// Ask #89 A: a saved recording is sealed at once, and its plain audio
    /// stays on the phone (what a removal holds) until the Mac confirms it.
    func testASavedRecordingIsSealedAndKeepsItsPlainAudio() async throws {
        let root = try makeRoot(links: [linkRecord()])
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let recordings = paths.recordingsDirectory(TestHub.acme)
        let row = try XCTUnwrap(try root.env.store.phoneRecording(id: id))
        let sealed = try XCTUnwrap(row.sealedFileURL(in: recordings), "sealed at once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.fileURL(in: recordings).path), "the plain audio waits for the Mac")
    }

    private func heartbeat(
        updatedAt: Date, hubID: String = TestHub.acme, macName: String = "Acme Mac", flavor: HubFlavor = .default
    ) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt,
            appVersion: "1.0",
            hubID: hubID,
            macName: macName,
            flavor: flavor,
            lastPublishAt: updatedAt,
            lastRelayAt: updatedAt,
            relayBacklog: 0,
            accounts: [],
            enabledAt: updatedAt,
            ownerUser: "_owner-acme",
            sharing: .none
        )
    }
}

/// A transport whose fetches wait until `open()`: the environment's first
/// fetch is held for as long as the test needs.
private actor GatedTransport: CloudSyncTransport {
    private let inner = InMemoryCloudTransport()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.changes(in: zone, since: token)
    }
}

/// A link clock whose sleeps wait for `release()` and whose `now` stands
/// still: the grant wait polls once, then the test answers for the Mac.
private final class GateLinkClock: LinkClock, @unchecked Sendable {
    let start = Date()
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func now() -> Date { start }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
        try Task.checkCancellation()
    }

    func release() {
        let all = lock.withLock {
            let parked = waiters
            waiters = []
            return parked
        }
        all.forEach { $0.resume() }
    }
}

/// The test hub with its signing key swapped for a stranger's: everything else (hub id, recipient) is right.
private final class StrangerSignedHub: SecureKeyProvider, @unchecked Sendable {
    private let hub = TestE2E.hub(firstSeq: 9_000_000_000)
    private let stranger = Curve25519.Signing.PrivateKey()

    var role: SecureRole { hub.role }
    func metaKey() throws -> SymmetricKey { try hub.metaKey() }
    func currentEpoch() throws -> UInt32 { try hub.currentEpoch() }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { try hub.dataKey(epoch: epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { try hub.alertKey(epoch: epoch) }
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        try hub.relayKey(direction, deviceID: deviceID, epoch: epoch)
    }
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool { try hub.acceptsRelayEpoch(epoch, deviceID: deviceID) }
    func relayDeviceIDs() throws -> [UUID] { try hub.relayDeviceIDs() }
    func nextSeq() throws -> UInt64 { try hub.nextSeq() }
    func hubSigner() throws -> Curve25519.Signing.PrivateKey { stranger }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { try hub.hubAgreement() }
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? { try hub.keyboxRecipient(deviceID: deviceID) }
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { try hub.deviceSigner() }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { try hub.hubAgreementPublicKey() }
    func linkNonce() throws -> Data { try hub.linkNonce() }
}
