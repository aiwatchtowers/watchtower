import Foundation
import GRDB
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
/// that reads and writes.
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

    private func makeRoot() throws -> AppRoot {
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
            startWork: nil,
            // The in-memory zones send at once: the farewell left the queue.
            farewellDelivery: AppRoot.FarewellDelivery(isPending: { _, _ in false }, pause: .milliseconds(20))
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
        try await poll { self.linkClock.waiting == 1 }
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
}
