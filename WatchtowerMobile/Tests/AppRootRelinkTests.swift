import Foundation
import GRDB
import os
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A shared link ended and made again over the real wiring (board #147,
/// review #70.6): the link URL and Unlink run through `LinkingViewModel` on
/// a live `AppRoot`, each over the hub's zones in the owner's database (one
/// in-memory transport per hub that outlives its sessions, as CloudKit's
/// zones outlive the phone's replica). The unlink retires the session, closes
/// its databases, deletes its files and leaves the shares once its farewell
/// went out; a new link to that hub builds a fresh session at the same paths
/// that reads and writes. Also the unlink farewell kept for a later resend
/// (#143): kept before the wait, sent again by a direct save at each
/// activation, one retry at a time.
@MainActor
final class AppRootRelinkTests: XCTestCase {
    /// The Mac's iCloud user; this phone is signed in as another (`container`).
    private let owner = "_owner-acme"
    private let hubID = TestHub.acme
    private let dataShare = "https://www.icloud.com/share/acme-data"
    private let relayShare = "https://www.icloud.com/share/acme-relay"

    private var paths: HubPaths!
    private var registry: HubRegistry!
    private var container: FakeLinkContainer!
    private var keyStore: InMemoryPhoneKeyStore!
    private let linkClock = GateLinkClock()
    /// The hub's zones: every session of a hub runs over the same transport.
    private var zones: [String: InMemoryCloudTransport] = [:]
    /// Background work the root began and ended, by name.
    private var workBegun: [String] = []
    private var workEnded: [String] = []

    /// The in-memory zones send at once: the farewell left the queue.
    private static let sentAtOnce = AppRoot.FarewellDelivery(isPending: { _, _ in false }, pause: .milliseconds(20))

    private func makeRoot(farewellDelivery: AppRoot.FarewellDelivery = sentAtOnce) throws -> AppRoot {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("app-root-relink-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let linkClock = linkClock
        addTeardownBlock { linkClock.release() }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("group", isDirectory: true),
            localDirectory: base.appendingPathComponent("local", isDirectory: true),
            recordingsBase: base.appendingPathComponent("phone-recordings", isDirectory: true)
        )
        for directory in [paths.groupDirectory, paths.localDirectory, paths.recordingsBase] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.paths = paths
        let keyStore = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        self.keyStore = keyStore
        let defaults = try makeDefaults()
        registry = try HubRegistry(path: paths.registryPath)
        container = FakeLinkContainer(log: LinkEventLog())
        container.userRecordNameValue = "_colleague-a"
        let identity = DeviceIdentity(deviceID: try keyStore.deviceID()?.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0")
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let factory = HubSessionFactory { [weak self] _, hubID, scope, device in
            guard let self else { throw CancellationError() }
            try paths.prepare(hubID)
            let zone = zones[hubID] ?? InMemoryCloudTransport()
            zones[hubID] = zone
            let session = try HubSession(
                transport: zone,
                replicaPath: paths.replicaPath(hubID),
                transportKind: .cloudKit,
                hubID: hubID,
                linkedDevice: device,
                keys: PhoneKeys(store: keyStore, hubID: hubID),
                defaults: defaults,
                recordingsDirectory: paths.recordingsDirectory(hubID),
                hold: RecordingHold(directory: paths.holdDirectory),
                databaseScope: scope
            ) { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil
                )
            }
            // Before the temp directory goes (teardown blocks run last-in first-out); weak: the test checks a
            // retired session is freed.
            addTeardownBlock { @MainActor [weak session] in
                await session?.shutDown()
                session?.closeDatabases()
            }
            return session
        }
        let env = try AppEnvironment.live(
            registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults
        ) { _ in }
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
            startWork: { [weak self] name in
                self?.workBegun.append(name)
                return { self?.workEnded.append(name) }
            },
            farewellDelivery: farewellDelivery
        )
    }

    /// A shared link code of the test hub issued at `iat`.
    private func code(iat: Int64) -> LinkPayload {
        let plain = TestPhone.linkCode(iat: iat)
        return LinkPayload(
            hubID: plain.hubID, macName: plain.macName, ownerUser: owner, nonce: plain.nonce, iat: iat, exp: plain.exp,
            dataShare: dataShare, relayShare: relayShare, hubSigningKey: plain.hubSigningKey, hubAgreementKey: plain.hubAgreementKey
        )
    }

    /// Scans `code` on `root` and answers for the Mac with a linked keybox
    /// decided at the code's issue: the whole flow over the real host.
    private func link(_ root: AppRoot, _ code: LinkPayload) async throws {
        let flow = Task { await root.open(code.url()) }
        await waitUntilParked(linkClock)
        XCTAssertEqual(root.linking.phase, .waiting(macName: "Acme Mac"))
        let deviceID = TestE2E.deviceID.uuidString
        let linkedAt = Date(timeIntervalSince1970: TimeInterval(code.iat))
        let grant = DeviceGrant(
            deviceID: deviceID, hubID: hubID, name: "Colleague A's iPhone", scope: .shared,
            linked: true, linkedAt: linkedAt, typingAllowed: false, startSessionsAllowed: true
        )
        try await TestPhone.hub(over: try zone()).save([try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(), modifiedAt: linkedAt)])
        linkClock.release()
        // Bounded: a grant that never lands parks the flow on the clock again.
        let finished = expectation(description: "the link flow finished")
        Task {
            await flow.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        flow.cancel()
        XCTAssertEqual(root.linking.phase, .linked(macName: "Acme Mac"))
    }

    /// A kept farewell of the test hub (#143), its sealed record `payload`.
    private func keptFarewell(_ payload: Data = Data([1])) -> PendingFarewell {
        PendingFarewell(
            hubID: hubID, scope: .shared(ownerName: owner), userRecordName: "_colleague-a",
            record: CloudRecord(recordName: "wire", zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: payload),
            since: Date()
        )
    }

    private func zone() throws -> InMemoryCloudTransport {
        try XCTUnwrap(zones[hubID], "no zones of the hub")
    }

    private func hubFilesExist() -> [Bool] {
        [paths.hubDirectory(hubID), paths.localHubDirectory(hubID), paths.recordingsDirectory(hubID)]
            .map { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The session reads what the Mac publishes and writes its own device record.
    private func assertReadsAndWrites(_ session: HubSession, heartbeatAt updatedAt: Date) async throws {
        let heartbeat = HeartbeatPayload(
            updatedAt: updatedAt, appVersion: "1.0", hubID: hubID, macName: "Acme Mac", flavor: .default,
            lastPublishAt: updatedAt, lastRelayAt: updatedAt, relayBacklog: 0, accounts: [], enabledAt: updatedAt,
            ownerUser: owner, sharing: .none
        )
        try await TestHub.hub(over: try zone(), hubID).save([try CloudRecordFactory.record(for: heartbeat, modifiedAt: updatedAt)])
        _ = await session.refresh(.pull)
        try await poll({ session.heartbeat?.updatedAt == updatedAt }, "the replica reads the Mac's heartbeat")
        let typing = !session.deviceSettings.typingRequested
        await session.deviceSettings.setTypingRequested(typing)
        XCTAssertNil(session.deviceSettings.lastError)
        let written = try await TestPhone.deviceWrites(in: try zone()).last
        XCTAssertEqual(written?.typingRequested, typing, "the device record went into the hub's zones")
        XCTAssertNil(written?.unlinked)
    }

    func testASharedUnlinkRetiresTheSessionAndARelinkOfThatHubWorksAtTheSamePaths() async throws {
        let root = try makeRoot()
        let start = Int64(linkClock.start.timeIntervalSince1970)
        try await link(root, code(iat: start))
        weak var first = root.env.session(hubID)
        let firstReader = try XCTUnwrap(first?.store.reader)
        XCTAssertEqual(first?.databaseScope, .shared(ownerName: owner), "another Apple ID: the shared database")
        try await assertReadsAndWrites(try XCTUnwrap(first), heartbeatAt: Date(timeIntervalSince1970: 1_800_000_000))

        await root.linking.unlink(hubID)

        XCTAssertNil(root.env.session(hubID), "the session is retired")
        XCTAssertFalse(first?.isLooping ?? false, "and stopped")
        XCTAssertTrue(root.env.holdsRetainedSession, "kept for the forwarders while Welcome takes the screen")
        assertClosed(firstReader)
        XCTAssertEqual(hubFilesExist(), [false, false, false], "its replica, transport and audio folders are gone")
        XCTAssertNil(try registry.row(hubID))
        XCTAssertTrue(try registry.pendingFarewells().isEmpty, "the farewell went out: nothing kept")
        let farewell = try await TestPhone.deviceWrites(in: try zone()).last
        XCTAssertEqual(farewell?.unlinked, true, "unlinked reached the hub's zones")
        XCTAssertEqual(container.leftHubIDs, [hubID], "the shares are left once the farewell is out")
        XCTAssertEqual(container.left, [owner])
        XCTAssertNil(try keyStore.hubLink(hubID), "its keys went with it")
        XCTAssertTrue(root.showsOnboarding)
        XCTAssertEqual(root.linking.phase, .idle)

        try await link(root, code(iat: start + 60))

        let second = try XCTUnwrap(root.env.session(hubID), "a new session of the same hub")
        XCTAssertFalse(second === first)
        XCTAssertFalse(root.env.holdsRetainedSession, "the relinked hub's activation let the retired one go")
        try await poll({ first == nil }, "the retired session (and its replica) is freed")
        XCTAssertEqual(container.accepted.count, 2, "the shares are accepted again")
        XCTAssertEqual(second.databaseScope, .shared(ownerName: owner))
        XCTAssertEqual(try registry.rows().map(\.hubID), [hubID])
        XCTAssertEqual(root.env.activeHubID, hubID)
        XCTAssertFalse(root.showsOnboarding)
        XCTAssertEqual(hubFilesExist(), [true, true, true], "the hub's folders are made again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.replicaPath(hubID)), "the replica at the same path")
        try await assertReadsAndWrites(second, heartbeatAt: Date(timeIntervalSince1970: 1_800_000_600))
    }

    // MARK: - The test clock (#683)

    /// `link` waits for the grant wait's poll by a signal: a flow that parks
    /// only after the wait began (a stalled runner) is still seen, and the
    /// one release reaches it. A wall-clock check that gave up first left the
    /// flow parked for good and failed the relink on CI.
    func testTheGateClockSignalsAParkThatComesAfterTheWaitBegan() async throws {
        let clock = GateLinkClock()
        addTeardownBlock { clock.release() }
        let watch = Task { await clock.untilParked() }
        try await poll { clock.watching == 1 }
        XCTAssertEqual(clock.waiting, 0, "nothing parked yet: the watcher waits for a park")
        let sleeper = Task { try await clock.sleep(for: .seconds(2)) }

        await watch.value

        XCTAssertEqual(clock.waiting, 1)
        await clock.untilParked()
        clock.release()
        try await sleeper.value
        XCTAssertEqual(clock.waiting, 0)
        let next = Task { await clock.untilParked() }
        try await poll { clock.watching == 1 }
        let nextSleeper = Task { try await clock.sleep(for: .seconds(2)) }
        await next.value
        XCTAssertEqual(clock.waiting, 1, "after a release, the next park")
        clock.release()
        try await nextSleeper.value
        let cancelled = Task { await clock.untilParked() }
        try await poll { clock.watching == 1 }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(clock.watching, 0, "a cancelled wait leaves no watcher")
    }

    // MARK: - The kept farewell (#143)

    /// Review round 1 (F8): the farewell is kept in the registry before the
    /// wait (a kill during it keeps it) and dropped once it went out.
    func testAnUnlinkKeepsItsFarewellDuringTheWaitAndDropsItOnceSent() async throws {
        var keptWhileWaiting: [Bool] = []
        let root = try makeRoot(farewellDelivery: AppRoot.FarewellDelivery(
            isPending: { [weak self] _, _ in
                keptWhileWaiting.append(self?.registry.map { (try? $0.pendingFarewells().isEmpty) == false } ?? false)
                return false
            },
            pause: .milliseconds(20)
        ))
        try await link(root, code(iat: Int64(linkClock.start.timeIntervalSince1970)))

        await root.linking.unlink(hubID)

        XCTAssertEqual(keptWhileWaiting, [true], "kept before the look at the queue")
        XCTAssertTrue(try registry.pendingFarewells().isEmpty, "sent: no longer kept")
        XCTAssertEqual(container.leftHubIDs, [hubID])
    }

    /// Review round 1 (F4/F5): the production resend, one direct save of the
    /// kept sealed record (`AppRoot.resendDirectly`): a save that fails keeps
    /// it, one that returns drops it.
    func testAKeptFarewellGoesOutByADirectSaveAndStaysKeptOnAnError() async throws {
        let saved = OSAllocatedUnfairLock(initialState: [PendingFarewell]())
        let fails = OSAllocatedUnfairLock(initialState: true)
        var delivery = Self.sentAtOnce
        delivery.resend = { farewell in
            await AppRoot.resendDirectly(farewell, cap: .seconds(10)) { farewell in
                saved.withLock { $0.append(farewell) }
                if fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            }
        }
        let root = try makeRoot(farewellDelivery: delivery)
        try registry.savePendingFarewell(keptFarewell())

        let first = await root.resendFarewell(try XCTUnwrap(try registry.pendingFarewells().first))

        XCTAssertFalse(first)
        XCTAssertEqual(try registry.pendingFarewells().map(\.hubID), [hubID], "a failed save keeps it")

        fails.withLock { $0 = false }
        let second = await root.resendFarewell(try XCTUnwrap(try registry.pendingFarewells().first))

        XCTAssertTrue(second)
        XCTAssertTrue(try registry.pendingFarewells().isEmpty)
        XCTAssertEqual(saved.withLock { $0.map(\.record.payload) }, [Data([1]), Data([1])], "the sealed record as kept")
        XCTAssertEqual(saved.withLock { $0.last?.scope }, .shared(ownerName: owner))
    }

    /// Review round 1 (F4): a direct save still running at the cap reads as
    /// not sent, at once.
    func testADirectSaveStillRunningAtTheCapIsNotSent() async {
        let started = ContinuousClock.now

        let sent = await AppRoot.resendDirectly(keptFarewell(), cap: .milliseconds(100)) { _ in
            try await Task.sleep(for: .seconds(60))
        }

        XCTAssertFalse(sent)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "the cap ended it")
    }

    /// Review round 1 (F10/F4): each activation retries the kept farewells
    /// inside background work, one retry at a time.
    func testAnActivationRetriesTheKeptFarewellsOnceAtATimeInBackgroundWork() async throws {
        var resends: [String] = []
        var delivery = Self.sentAtOnce
        delivery.resend = { farewell in
            resends.append(farewell.hubID)
            return true
        }
        let root = try makeRoot(farewellDelivery: delivery)
        try registry.savePendingFarewell(keptFarewell())

        let first = root.becameActive()
        let second = root.becameActive()
        await first.value

        XCTAssertEqual(first, second, "a second activation joins the running retry")
        XCTAssertEqual(resends, [hubID])
        XCTAssertTrue(try registry.pendingFarewells().isEmpty)
        XCTAssertEqual(container.leftHubIDs, [hubID], "out: the shares are left")
        XCTAssertEqual(workBegun, ["hub-farewells"])
        XCTAssertEqual(workEnded, ["hub-farewells"])

        await root.becameActive().value
        XCTAssertEqual(resends, [hubID], "nothing kept: nothing sent")
    }
}
