import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Following the hub's transport switch (relay client Phase 3 Task 11; sim rules 12a, 13 and R32): the live `AppRoot`
/// as the follower's host, one hub whose CloudKit route is an `InMemoryCloudTransport` and whose relay route is
/// `HostedRelayTransport` on `FakeHostedRelay`, and a scripted hub writing sealed controls and markers on either.
@MainActor
final class TransportFollowerWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString
    private let deviceID = TestE2E.deviceID.uuidString

    // MARK: - Switches

    func testSwitchedToRelayMovesTheHubAndResendsTheSameBytes() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        let envelopes = try await bed.sendTwoActions(first)
        let cloudWrites = await bed.cloud.conditionalSaves.count

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)

        let link = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(link.transport, .relay)
        XCTAssertEqual(link.leftTransport, .cloudKit)
        XCTAssertEqual(link.switchedBy, deviceID)
        XCTAssertEqual(link.switchedAt, Bed.switchedAt)
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        let onRelay = try await bed.relayMailbox()
        for envelope in envelopes {
            XCTAssertTrue(onRelay.contains { $0.envelope == envelope }, "the same bytes on the relay")
        }
        let cloudAfter = await bed.cloud.conditionalSaves.count
        XCTAssertEqual(cloudAfter, cloudWrites, "nothing more written on the transport the hub left")
        XCTAssertEqual(try Bed.rows(second, .sent).count, 2, "sent again on the relay")
        let cloudNames = try await bed.cloudMailboxNames()
        XCTAssertFalse(cloudNames.contains(try bed.switchWire), "the control is deleted where it was read")
    }

    func testSwitchedToCloudKitMovesBack() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let envelopes = try await bed.sendTwoActions(first)

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        let second = try await bed.fetchAndFollow(first)

        let link = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(link.transport, .cloudKit)
        XCTAssertEqual(link.leftTransport, .relay)
        XCTAssertEqual(link.relayMacDeviceID, bed.mac.deviceID, "kept for a later switch back")
        XCTAssertEqual(second.route, .cloudKit(.private))
        let onCloud = try await bed.cloudMailbox()
        for envelope in envelopes {
            XCTAssertTrue(onCloud.contains { $0.payload == envelope }, "the same bytes on CloudKit")
        }
    }

    func testTheKeyboxInsideSwitchedIsMergedAndAcked() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)

        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        let acks = try await bed.relayControls(.epochAck)
        XCTAssertEqual(acks.map(\.epoch), [2], "acknowledged once, on the new transport")
        let cloudAcks = try await bed.cloudControls(.epochAck)
        XCTAssertEqual(cloudAcks.map(\.epoch), [1], "only the adoption's ack on the transport the hub left")
        XCTAssertTrue(try Bed.handled(second, bed.switchID))
    }

    // MARK: - The marker

    func testAMarkerLeadsAReturningPhone() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()

        try await bed.writeMarker(target: .relay, epoch: 2)
        let second = try await bed.fetchAndFollow(first)

        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1], "no keybox in a marker")
    }

    func testAnOlderMarkerIsIgnored() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()

        try await bed.writeMarker(target: .relay, epoch: 1)
        await bed.fetch(first)
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertTrue(bed.root.env.session(hubID) === first)

        // The marker channel is live: a newer one in the same bed moves the phone.
        try await bed.writeMarker(target: .relay, epoch: 2)
        let second = try await bed.fetchAndFollow(first)
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
    }

    // MARK: - R32

    func testHubOnRelayListsUnechoedAsNotDelivered() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        try await bed.sendTwoActions(first)
        bed.relayOps.paying = false

        let control = try await bed.writeHubControl(.hubOnRelay, on: .cloudKit)
        await bed.fetch(first)

        let listed = try Bed.rows(first, .undelivered)
        XCTAssertEqual(listed.count, 2)
        let pending = try first.store.pendingActions().filter { $0.delivery == .undelivered }
        XCTAssertEqual(Set(pending.map(\.undeliveredReason)), [.hubOnRelay])
        XCTAssertTrue(try Bed.handled(first, control.id))
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit, "the phone stays where it can reach")
        XCTAssertTrue(bed.root.env.session(hubID) === first)
    }

    func testSwitchedToRelayOnAFreePhoneActsAsHubOnRelay() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        try await bed.sendTwoActions(first)
        bed.relayOps.paying = false

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        await bed.fetch(first)
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try Bed.rows(first, .undelivered).count, 2)
        XCTAssertTrue(try Bed.handled(first, bed.switchID))
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1], "a free phone takes no relay epoch")
        XCTAssertTrue(bed.root.env.session(hubID) === first)
    }

    func testAFailedAccountStateKeepsThePhoneOnItsRouteAndRetries() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        try await bed.sendTwoActions(first)
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.unreachable)

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        await bed.fetch(first)

        XCTAssertFalse(try Bed.handled(first, bed.switchID))
        let cloudNames = try await bed.cloudMailboxNames()
        XCTAssertTrue(cloudNames.contains(try bed.switchWire), "left in the mailbox")
        XCTAssertEqual(try Bed.rows(first, .sent).count, 2, "nothing moved to Not delivered")
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(bed.root.routeMoves[hubID])

        // The next pass asks again; the relay answers this time.
        let second = try await bed.fetchAndFollow(first)
        XCTAssertEqual(bed.relayOps.count("accountState"), 2)
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
    }

    // MARK: - What a move keeps and drops

    func testARouteChangeSweepsSlicesTheNewTransportDidNotReturn() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        try await bed.publishBriefings(["kept", "gone"], on: .cloudKit)
        await bed.fetch(first)
        XCTAssertEqual(try bed.briefings(first), ["briefing-gone", "briefing-kept"])
        try await bed.publishBriefings(["kept"], on: .relay)

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)
        await bed.fetch(second)

        XCTAssertEqual(try bed.briefings(second), ["briefing-kept"])
        XCTAssertNotNil(try second.keybox(deviceID: TestE2E.deviceID), "the keybox stays")
        XCTAssertFalse(try second.store.sweepsAfterFullPull())
    }

    func testTheOutboxAndKeysSurviveARouteChange() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        await bed.cloud.refuse(.unreachable)
        try await bed.sendTwoActions(first)
        let watermark = Date(timeIntervalSince1970: 1_800_000_000)
        try first.store.setLastAlertedWatermark(watermark)
        let ids = try Bed.rows(first, .queued).map(\.id)

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)

        XCTAssertEqual(try Bed.rows(second, .sent).map(\.id), ids, "the same rows, sent on the relay")
        XCTAssertEqual(try second.store.lastAlertedWatermark(), watermark)
        XCTAssertTrue(try Bed.handled(second, bed.switchID))
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        let ordered = try await second.outbox.orderedActions()
        XCTAssertTrue(ordered, "the ordered path stays on")
    }

    // MARK: - Paths and phones

    func testALegacyPathPhoneFollowsToo() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try bed.session()
        await first.waitForBoot()
        try await bed.publishGrant(ordered: false)
        await bed.fetch(first)
        let ordered = try await first.outbox.orderedActions()
        XCTAssertFalse(ordered)

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)

        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
    }

    /// In one batch: another phone's switch (it does not open here) is neither answered nor deleted, while this
    /// phone's own switch is followed and deleted.
    func testAnotherPhonesControlIsLeftAlone() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()

        let wire = try await bed.writeSwitchForAStranger()
        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)

        let names = try await bed.cloudMailboxNames()
        XCTAssertTrue(names.contains(wire), "neither deleted nor answered")
        XCTAssertFalse(names.contains(try bed.switchWire), "this phone's own switch is deleted")
        XCTAssertTrue(try Bed.handled(second, bed.switchID))
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        let deletes = await bed.cloud.conditionalDeletes
        XCTAssertFalse(deletes.contains { $0.recordName == wire })
    }

    /// Review round 1: a keybox merge that fails after the move was written leaves the control undecided; the next
    /// pass finds the row already moved, merges, and still moves the session.
    func testAFailedMergeAfterThePersistedMoveRecoversNextPass() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        let envelopes = try await bed.sendTwoActions(first)
        let flaky = FlakyMergeHost(root: bed.root)
        let follower = TransportFollower(hubID: hubID, outbox: first.outbox, host: flaky)
        first.transportSignals.onControl = { control in await follower.handle(control: control, on: .cloudKit) }

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        await bed.fetch(first)
        XCTAssertEqual(try bed.row()?.link.transport, .relay, "the move was written")
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1], "the merge failed")
        XCTAssertFalse(try Bed.handled(first, bed.switchID))
        XCTAssertTrue(bed.root.env.session(hubID) === first)

        let second = try await bed.fetchAndFollow(first)
        XCTAssertEqual(flaky.merges, 2)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        XCTAssertEqual(second.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        let onRelay = try await bed.relayMailbox()
        for envelope in envelopes {
            XCTAssertTrue(onRelay.contains { $0.envelope == envelope }, "flushed on the relay")
        }
    }

    /// Review round 1: a relay-only hub (its transports exclude CloudKit) is never moved to CloudKit, whose zones it
    /// does not have; the outbox is neither held nor emptied and the control stays.
    func testARelayOnlyHubIsNeverMovedToCloudKit() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let first = try await bed.orderedSession()
        try await bed.sendTwoActions(first)
        bed.relayOps.paying = false

        let control = try await bed.writeHubControl(.hubOnRelay, on: .relay)
        await bed.fetch(first)
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertNil(try bed.row()?.link.leftTransport)
        XCTAssertTrue(bed.root.env.session(hubID) === first)
        XCTAssertFalse(try Bed.handled(first, control.id))
        XCTAssertTrue(try Bed.rows(first, .undelivered).isEmpty, "nothing listed")
        XCTAssertEqual(try Bed.rows(first, .sent).count, 2)
    }

    /// The follower writes the move before it reports the control handled: a kill between the two leaves the move on
    /// the row and the control in the mailbox, and the control read again changes nothing twice.
    func testTheMoveIsPersistedBeforeTheControlIsDeleted() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        try await bed.sendTwoActions(first)
        let control = try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)

        // The follower alone, as the feed calls it: the process dies before the feed marks and deletes.
        let follower = TransportFollower(hubID: hubID, outbox: first.outbox, host: bed.root)
        let decided = await follower.handle(control: control, on: .cloudKit)
        XCTAssertTrue(decided)
        let moved = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(moved.transport, .relay, "persisted before the control is deleted")
        XCTAssertFalse(try Bed.handled(first, control.id))
        let cloudNames = try await bed.cloudMailboxNames()
        XCTAssertTrue(cloudNames.contains(try bed.switchWire))
        await bed.root.routeMoves[hubID]?.value
        let second = try XCTUnwrap(bed.root.env.session(hubID))
        await second.waitForBoot()
        await second.outboxWork?.value
        await second.outbox.drain()
        let relayWrites = try await bed.relayMailbox().count

        // Read again: the same epoch on the same route answers the request and changes nothing.
        let again = TransportFollower(hubID: hubID, outbox: second.outbox, host: bed.root)
        let decidedAgain = await again.handle(control: control, on: .cloudKit)
        await bed.root.routeMoves[hubID]?.value
        XCTAssertTrue(decidedAgain)
        XCTAssertEqual(try bed.row()?.link, moved)
        XCTAssertTrue(bed.root.env.session(hubID) === second, "no second move")
        XCTAssertEqual(try Bed.rows(second, .sent).count, 2, "nothing queued again")
        await second.outbox.drain()
        let relayAfter = try await bed.relayMailbox().count
        XCTAssertEqual(relayAfter, relayWrites)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
    }
}

// MARK: - The bed

/// One hub, two routes: CloudKit (`cloud`, in memory) and the relay (`FakeHostedRelay`, the Mac `mac`), the live root
/// over them, and the scripted hub.
@MainActor
private final class Bed {
    static let switchedAt = Date(timeIntervalSince1970: 1_800_000_100)
    let hubID = TestE2E.hubID.uuidString
    let phone: HostedRelayClient
    let mac: HostedRelayClient
    let cloud: RecordingCloud
    let keys: InMemoryPhoneKeyStore
    let relayOps: FakeRelayOps
    let root: AppRoot
    let registry: HubRegistry
    /// The last `transport_switched` written.
    private(set) var switchID = ""
    private(set) var switchName = ""

    private init(
        phone: HostedRelayClient,
        mac: HostedRelayClient,
        cloud: RecordingCloud,
        keys: InMemoryPhoneKeyStore,
        relayOps: FakeRelayOps,
        root: AppRoot,
        registry: HubRegistry
    ) {
        self.phone = phone
        self.mac = mac
        self.cloud = cloud
        self.keys = keys
        self.relayOps = relayOps
        self.root = root
        self.registry = registry
    }

    static func make(
        _ test: XCTestCase, on route: TransportKind, hubTransports: [String] = ["cloudkit", "relay"]
    ) async throws -> Bed {
        let relayClock = ManualRelayClock(now: Date())
        let fake = FakeHostedRelay(attest: .off, clock: relayClock)
        let parts = RelayParts(
            attest: FakeAppAttest(), keychain: InMemoryKeychainBackend(), keychainGroup: nil, http: fake.http,
            sockets: fake.sockets, clock: relayClock
        )
        let shared = SharedRelaySession(config: RelayConfig.parse(fake.origin)) { parts }
        let phone = try XCTUnwrap(try shared.session()).client
        _ = try await phone.register()
        try await phone.login()
        let account = try await fake.accountID(ofPhone: phone.deviceID)
        try await fake.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
        let macKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let mac = HostedRelayClient(
            origin: try RelayOrigin(fake.origin), signer: Ed25519RelaySigner(macKey), kind: .mac,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: relayClock),
            http: fake.http, sockets: fake.sockets, clock: relayClock
        )
        _ = try await mac.register()
        try await mac.login()
        try await fake.pair(mac: mac.deviceID, phones: [phone.deviceID])

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("follower-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("group", isDirectory: true),
            localDirectory: base.appendingPathComponent("local", isDirectory: true),
            recordingsBase: base.appendingPathComponent("recordings", isDirectory: true)
        )
        let keys = try TestE2E.phoneStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "follower-\(UUID().uuidString)"))
        let registry = try HubRegistry.inMemory()
        var link = LinkRecord(
            hubID: TestE2E.hubID.uuidString, macName: "Work Mac", scope: .private, ownerName: "",
            userRecordName: "_owner-acme", nonce: "nonce", dataShareURL: nil, relayShareURL: nil,
            deviceID: TestE2E.deviceID.uuidString, linkedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transport: .cloudKit, relayMacDeviceID: mac.deviceID, hubTransports: hubTransports
        )
        if route == .relay { link.setRelay(mac: mac.deviceID) }
        try registry.upsert(link, now: Date())
        let identity = DeviceIdentity(
            deviceID: TestE2E.deviceID.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0")
        let cloud = RecordingCloud()
        let factory = Self.factory(paths: paths, cloud: cloud, shared: shared, keys: keys, defaults: defaults)
        let relayOps = FakeRelayOps(clock: FakeLinkClock(now: Date()))
        let env = try AppEnvironment.live(
            registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults, relay: shared
        ) { _ in }
        let root = AppRoot(
            env: env, registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults,
            linking: LinkingViewModel(
                access: FakeLinkAccess(log: LinkEventLog()), store: LinkStore(defaults: defaults), identity: identity,
                keys: keys, clock: FakeLinkClock(now: Date()), relay: relayOps
            ),
            startWork: nil,
            farewellDelivery: AppRoot.FarewellDelivery { _, _ in false }
        )
        root.linking.refreshLinks()
        test.addTeardownBlock { @MainActor in
            for session in root.env.sessions.values {
                await session.shutDown()
                session.closeDatabases()
            }
        }
        return Bed(phone: phone, mac: mac, cloud: cloud, keys: keys, relayOps: relayOps, root: root, registry: registry)
    }

    /// Sessions on the hub's own files: CloudKit on `cloud`, the relay on `shared`'s session over the route's own store.
    private static func factory(
        paths: HubPaths,
        cloud: RecordingCloud,
        shared: SharedRelaySession,
        keys: InMemoryPhoneKeyStore,
        defaults: UserDefaults
    ) -> HubSessionFactory {
        HubSessionFactory { _, hubID, route, device in
            try paths.prepare(hubID)
            let transport: any CloudSyncTransport & Sendable
            var store: TransportStore?
            switch route {
            case .cloudKit:
                transport = cloud
            case .hostedRelay(let macDeviceID):
                let opened = try TransportStore(path: paths.transportStorePath(hubID, route: route))
                store = opened
                transport = try HostedRelayTransport(
                    session: try XCTUnwrap(try shared.session()), store: opened, macDeviceID: macDeviceID, mode: .hub)
            }
            let sleeper = TickSleeper()
            return try HubSession(
                transport: transport, replicaPath: paths.replicaPath(hubID), backend: .live, transportStore: store,
                hubID: hubID, linkedDevice: device, keys: PhoneKeys(store: keys, hubID: hubID), defaults: defaults,
                recordingsDirectory: paths.recordingsDirectory(hubID), route: route, uploadRetriesAllowed: false,
                sleep: { try await sleeper.sleep($0) } // swiftlint:disable:this trailing_closure
            )
        }
    }

    // MARK: Sessions

    func session() throws -> HubSession {
        try XCTUnwrap(root.env.session(hubID))
    }

    /// The booted session, its grant turning the ordered path on, the adoption's ack written.
    func orderedSession() async throws -> HubSession {
        let session = try session()
        await session.waitForBoot()
        try await publishGrant(ordered: true)
        await fetch(session)
        let on = try await session.outbox.orderedActions()
        XCTAssertTrue(on)
        await session.epochAckWork?.value
        await session.outbox.drain()
        return session
    }

    /// One fetch, then the outbox work it started.
    func fetch(_ session: HubSession) async {
        _ = await session.refresh(.pull)
        await session.outboxWork?.value
        await session.outbox.drain()
    }

    /// A fetch that follows a move: the move, then the new session booted and its outbox flushed.
    func fetchAndFollow(_ session: HubSession) async throws -> HubSession {
        await fetch(session)
        await root.routeMoves[hubID]?.value
        let next = try self.session()
        XCTAssertFalse(next === session, "the session moved")
        await next.waitForBoot()
        await fetch(next)
        await next.epochAckWork?.value
        await next.outbox.drain()
        return next
    }

    func row() throws -> HubRow? {
        try registry.row(hubID)
    }

    /// Two board moves through the outbox; their sealed envelopes.
    @discardableResult
    func sendTwoActions(_ session: HubSession) async throws -> [Data] {
        for target in ["target-41", "target-42"] {
            _ = try await session.outbox.enqueue(kind: .targetDone, entityRecordName: target)
        }
        _ = try? await session.outbox.flush()
        return try await session.store.reader.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM pending_actions WHERE action_seq IS NOT NULL ORDER BY action_seq")
        }
    }

    /// The ordered rows in `delivery`, by seq.
    static func rows(_ session: HubSession, _ delivery: Delivery) throws -> [PendingAction] {
        try session.store.pendingActions().filter { $0.delivery == delivery }.sorted { ($0.actionSeq ?? 0) < ($1.actionSeq ?? 0) }
    }

    /// Whether the session's replica marked the hub control `id` handled.
    static func handled(_ session: HubSession, _ id: String) throws -> Bool {
        try session.store.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM handled_controls WHERE control_id = ?", arguments: [id]) ?? false
        }
    }

    func briefings(_ session: HubSession) throws -> [String] {
        try session.store.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT plain_name FROM slice_records WHERE kind = ? ORDER BY plain_name",
                arguments: [SliceKind.briefing.rawValue])
        }
    }

    // MARK: The scripted hub

    func publishGrant(ordered: Bool) async throws {
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, mayStartSessions: true,
            orderedActions: ordered ? 1 : nil)
        // A heartbeat after `linkedAt`: the link came alive, so a `hub_on_relay` never ends it (Task 10).
        let now = Date()
        let heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: hubID, macName: "Work Mac", flavor: .default, lastPublishAt: now,
            lastRelayAt: now, relayBacklog: 0, accounts: [], enabledAt: now, ownerUser: "_owner-acme", sharing: .none)
        let records = [try TestPhone.grantRecord(grant, modifiedAt: now), try CloudRecordFactory.record(for: heartbeat, modifiedAt: now)]
        if try row()?.link.transport == .relay {
            for record in records { try await macSave(record, zone: "data/\(mac.deviceID)") }
        } else {
            try await TestPhone.hub(over: cloud.inner).save(records)
        }
    }

    func publishBriefings(_ ids: [String], on route: TransportKind) async throws {
        let records = ids.map {
            CloudRecordFactory.record(for: SliceRecord(kind: .briefing, id: $0, modifiedAt: Date(), payload: Data("{}".utf8)))
        }
        switch route {
        case .cloudKit: try await TestPhone.hub(over: cloud.inner).save(records)
        case .relay: for record in records { try await macSave(record, zone: "data/\(mac.deviceID)") }
        }
    }

    /// The sealed keybox of `epoch` for this phone, as `transport_switched` carries it (base64url).
    private func sealedKeybox(epoch: UInt32) async throws -> String {
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        let capture = InMemoryCloudTransport()
        try await TestPhone.hub(over: capture).save([
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(epoch: epoch), modifiedAt: Date())
        ])
        let batch = try await capture.changes(in: .data, since: nil)
        let sealed = try XCTUnwrap(batch.changed.first)
        return WireBytes.base64URL(sealed.payload)
    }

    /// `transport_switched{target, epoch}` from this phone's own switch, with the new epoch's keybox, on `route`.
    @discardableResult
    func writeSwitch(target: TransportKind, epoch: UInt32, on route: TransportKind) async throws -> ControlPayload {
        let control = ControlPayload(
            id: UUID().uuidString, kind: .transportSwitched, deviceID: TestE2E.deviceID.uuidString, hubID: hubID,
            epoch: epoch, target: target.rawValue, by: TestE2E.deviceID.uuidString, at: Self.switchedAt,
            keybox: try await sealedKeybox(epoch: epoch))
        switchID = control.id
        switchName = control.recordName
        try await writeControl(control, on: route)
        return control
    }

    var switchWire: String {
        get throws { try TestPhone.transport().wireName(plain: switchName, zone: .relay) }
    }

    @discardableResult
    func writeHubControl(_ kind: ControlKind, on route: TransportKind) async throws -> ControlPayload {
        let control = ControlPayload(id: UUID().uuidString, kind: kind, deviceID: TestE2E.deviceID.uuidString, hubID: hubID)
        try await writeControl(control, on: route)
        return control
    }

    /// A `transport_switched` for another phone of the hub, sealed to that phone's relay key, in the shared CloudKit
    /// zone; its wire name.
    func writeSwitchForAStranger() async throws -> String {
        let strangerID = TestE2E.strangerDeviceID
        let control = ControlPayload(
            id: UUID().uuidString, kind: .transportSwitched, deviceID: strangerID.uuidString, hubID: hubID, epoch: 2,
            target: "relay", by: strangerID.uuidString, at: Self.switchedAt)
        let record = try sealedControl(control, to: strangerID)
        try await cloud.inner.save([record])
        return record.recordName
    }

    /// The marker of a switch to `target` in `epoch`, in the CloudKit data zone.
    func writeMarker(target: TransportKind, epoch: UInt32) async throws {
        let body: [String: Any] = [
            "id": UUID().uuidString, "kind": "transport_switched", "hub_id": hubID, "target": target.rawValue,
            "epoch": epoch, "by": TestE2E.deviceID.uuidString, "at": Self.switchedAt.timeIntervalSince1970
        ]
        let plain = CloudRecord(
            recordName: TransportMarker.recordName, zone: .data, kind: TransportMarker.kind, modifiedAt: Date(),
            payload: try JSONSerialization.data(withJSONObject: body))
        try await cloud.inner.save([try TestE2E.sealedDataRecord(plain, seq: TestPhone.nextSeqBlock())])
    }

    private func writeControl(_ control: ControlPayload, on route: TransportKind) async throws {
        let record = try sealedControl(control, to: TestE2E.deviceID)
        switch route {
        case .cloudKit: try await cloud.inner.save([record])
        case .relay: try await macSaveSealed(record, zone: "relay/\(mac.deviceID)/\(phone.deviceID)")
        }
    }

    /// `control` sealed to `device` as the Go hub's `sealControl` does.
    private func sealedControl(_ control: ControlPayload, to device: UUID) throws -> CloudRecord {
        let keys = TestE2E.hub(firstSeq: TestPhone.nextSeqBlock())
        if device == TestE2E.strangerDeviceID { keys.link(TestE2E.strangerIdentity) }
        let wire = try TestPhone.hub(over: InMemoryCloudTransport()).wireName(plain: control.recordName, zone: .relay)
        let frame = InnerFrame(
            kind: RelayRecordKind.control.rawValue, id: control.recordName,
            payload: try RelayCoder.makeEncoder().encode(control))
        let epoch = try keys.currentEpoch()
        let envelope = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .relayToPhone, key: try keys.relayKey(.hubToPhone, deviceID: device, epoch: epoch),
            hubID: TestE2E.hubID, senderID: TestE2E.hubID, epoch: epoch, seq: try keys.nextSeq(),
            context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
        return CloudRecord(recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: envelope)
    }

    /// `plain` sealed by the test hub into the relay zone `zone`.
    private func macSave(_ plain: CloudRecord, zone: String) async throws {
        let capture = InMemoryCloudTransport()
        try await TestPhone.hub(over: capture).save([plain])
        let batch = try await capture.changes(in: plain.zone, since: nil)
        let sealed = try XCTUnwrap(batch.changed.first)
        try await macSaveSealed(sealed, zone: zone)
    }

    private func macSaveSealed(_ sealed: CloudRecord, zone: String) async throws {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = sealed.recordName
        item.record.envelope = sealed.payload
        item.record.clientModifiedAtMs = Int64(sealed.modifiedAt.timeIntervalSince1970 * 1000)
        var save = Relay_V1_Save()
        save.items = [item]
        _ = try await mac.save(save)
    }

    // MARK: Reading the mailboxes

    func relayMailbox() async throws -> [Relay_V1_Record] {
        var changes = Relay_V1_Changes()
        changes.zone = "relay/\(mac.deviceID)/\(phone.deviceID)"
        return try await mac.changes(changes).changed
    }

    func cloudMailbox() async throws -> [CloudRecord] {
        try await cloud.inner.changes(in: .relay, since: nil).changed
    }

    func cloudMailboxNames() async throws -> Set<String> {
        Set(try await cloudMailbox().map(\.recordName))
    }

    /// The phone's own controls of `kind` on the relay, opened as the hub opens them.
    func relayControls(_ kind: ControlKind) async throws -> [ControlPayload] {
        let capture = InMemoryCloudTransport()
        let records = try await relayMailbox().map {
            CloudRecord(recordName: $0.name, zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: $0.envelope)
        }
        try await capture.save(records)
        return try await phoneControls(kind, in: capture)
    }

    func cloudControls(_ kind: ControlKind) async throws -> [ControlPayload] {
        try await phoneControls(kind, in: cloud.inner)
    }

    private func phoneControls(_ kind: ControlKind, in transport: InMemoryCloudTransport) async throws -> [ControlPayload] {
        let opened = try await TestPhone.transport(over: transport).changes(in: .relay, since: nil).changed
        return try opened
            .filter { $0.kind == RelayRecordKind.control.rawValue }
            .map { try RelayCoder.makeDecoder().decode(ControlPayload.self, from: $0.payload) }
            .filter { $0.kind == kind }
    }
}

/// The in-memory CloudKit stand-in: records every conditional save and delete; refuses saves while `refusal` is set.
actor RecordingCloud: ConditionalTransport {
    let inner = InMemoryCloudTransport()
    private var refusal: TransportRefusal?
    private(set) var conditionalSaves: [ConditionalSave] = []
    private(set) var conditionalDeletes: [ConditionalDelete] = []

    func refuse(_ refusal: TransportRefusal?) {
        self.refusal = refusal
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }

    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        conditionalSaves += items
        if let refusal { return items.map { _ in .refused(refusal) } }
        return try await inner.save(items)
    }

    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        conditionalDeletes += items
        return try await inner.delete(items)
    }
}

/// `AppRoot` as the follower's host, except that the first keybox merge fails (a Keychain error, say).
@MainActor
private final class FlakyMergeHost: TransportFollowerHost {
    private let root: AppRoot
    private(set) var merges = 0

    init(root: AppRoot) {
        self.root = root
    }

    func followerLink(hubID: String) -> LinkRecord? { root.followerLink(hubID: hubID) }
    func newestEpoch(hubID: String) -> UInt32? { root.newestEpoch(hubID: hubID) }
    func relayUse(for link: LinkRecord) async -> RelayUse { await root.relayUse(for: link) }
    func openSwitchKeybox(_ sealed: Data, hubID: String) async -> Keybox? { await root.openSwitchKeybox(sealed, hubID: hubID) }
    func persistRoute(_ link: LinkRecord) -> Bool { root.persistRoute(link) }
    func moveSession(hubID: String) { root.moveSession(hubID: hubID) }

    func mergeSwitchKeys(_ keybox: Keybox, hubID: String) async -> Bool {
        merges += 1
        return merges > 1 ? await root.mergeSwitchKeys(keybox, hubID: hubID) : false
    }
}
