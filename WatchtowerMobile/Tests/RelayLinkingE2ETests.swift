import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Counts the device's WebSocket dials and how many of its sockets are open at once.
private final class SocketCounter: RelaySocketDialer, @unchecked Sendable {
    private let inner: any RelaySocketDialer
    private let lock = NSLock()
    private var dialed = 0
    private var open = 0
    private var peak = 0

    init(inner: any RelaySocketDialer) {
        self.inner = inner
    }

    var dials: Int { lock.withLock { dialed } }
    var mostOpenAtOnce: Int { lock.withLock { peak } }

    func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        let socket = try await inner.dial(url, headers: headers)
        lock.withLock {
            dialed += 1
            open += 1
            peak = max(peak, open)
        }
        return CountedSocket(inner: socket) { [weak self] in
            guard let self else { return }
            lock.withLock { self.open -= 1 }
        }
    }
}

/// A socket that reports its end once: closed by the client, or its receive ended.
private final class CountedSocket: RelaySocket, @unchecked Sendable {
    private let inner: any RelaySocket
    private let lock = NSLock()
    private var ended = false
    private let onEnd: () -> Void

    init(inner: any RelaySocket, onEnd: @escaping () -> Void) {
        self.inner = inner
        self.onEnd = onEnd
    }

    private func end() {
        let first = lock.withLock {
            defer { ended = true }
            return !ended
        }
        if first { onEnd() }
    }

    func send(_ data: Data) async throws {
        try await inner.send(data)
    }

    func receive() async throws -> RelaySocketMessage {
        do {
            return try await inner.receive()
        } catch {
            end()
            throw error
        }
    }

    func ping() async throws {
        try await inner.ping()
    }

    func close(code: Int) async {
        await inner.close(code: code)
        end()
    }
}

/// Linking over the relay end to end (relay client Phase 3 Task 10, review round 1): the live `AppRoot` with
/// `HostedRelayLinkOps`, `TransportFactory.live(relay:)` (`makePairing`, then the hub mode on the same store) and
/// `HubSessionFactory.live`, over `FakeHostedRelay`; a test Mac on its own client answers in `pair/<slot>`.
@MainActor
final class RelayLinkingE2ETests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    private struct Bed {
        let fake: FakeHostedRelay
        let shared: SharedRelaySession
        let sockets: SocketCounter
        let phone: HostedRelayClient
        let mac: HostedRelayClient
        let macKey: Data
        let root: AppRoot
        let linkClock: GateLinkClock
        let defaults: UserDefaults
    }

    private func makeBed() async throws -> Bed {
        let relayClock = ManualRelayClock(now: Date())
        let fake = FakeHostedRelay(attest: .off, clock: relayClock)
        let sockets = SocketCounter(inner: fake.sockets)
        let parts = RelayParts(
            attest: FakeAppAttest(), keychain: InMemoryKeychainBackend(), keychainGroup: nil, http: fake.http,
            sockets: sockets, clock: relayClock
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

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("relay-e2e-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("group", isDirectory: true),
            localDirectory: base.appendingPathComponent("local", isDirectory: true),
            recordingsBase: base.appendingPathComponent("phone-recordings", isDirectory: true)
        )
        for directory in [paths.groupDirectory, paths.localDirectory, paths.recordingsBase] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let keyStore = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        let defaults = try makeDefaults()
        let registry = try HubRegistry(path: paths.registryPath)
        let identity = DeviceIdentity(
            deviceID: try keyStore.deviceID()?.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0"
        )
        let transports = TransportFactory.live(relay: shared)
        let factory = HubSessionFactory.live(paths: paths, keys: keyStore, transports: transports)
        let env = try AppEnvironment.live(
            registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults, relay: shared
        ) { _ in }
        let linkClock = GateLinkClock()
        addTeardownBlock { linkClock.release() }
        let root = AppRoot(
            env: env, registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults,
            linking: LinkingViewModel(
                access: FakeLinkAccess(log: LinkEventLog()), store: LinkStore(defaults: defaults), identity: identity,
                keys: keyStore, clock: linkClock, relay: HostedRelayLinkOps(relay: shared)
            ),
            startWork: nil,
            farewellDelivery: .live(transports: transports)
        )
        addTeardownBlock { @MainActor in
            for session in env.sessions.values {
                await session.shutDown()
                session.closeDatabases()
            }
        }
        return Bed(
            fake: fake, shared: shared, sockets: sockets, phone: phone, mac: mac, macKey: macKey.publicKey.rawRepresentation,
            root: root, linkClock: linkClock, defaults: defaults
        )
    }

    /// The Mac's relay code: v4, Relay only (a headless host), its relay identity.
    private func code(_ bed: Bed) -> LinkPayload {
        let iat = Int64(bed.linkClock.start.timeIntervalSince1970) - 10
        return LinkPayload(
            v: 4, container: nil, hubID: hubID, macName: "build-box", ownerUser: nil, nonce: LinkPayload.makeNonce(),
            iat: iat, exp: iat + LinkPayload.lifetime,
            hubSigningKey: WireBytes.base64URL(TestE2E.hubSigningKey.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(TestE2E.hubAgreementKey.publicKey.rawRepresentation),
            transport: .relay, transports: ["relay"], relayDeviceID: bed.mac.deviceID,
            relayAuthPub: WireBytes.base64URL(bed.macKey)
        )
    }

    /// `plain` sealed by the test hub, as a relay record of `zone`.
    private func macSave(_ mac: HostedRelayClient, zone: String, _ plain: CloudRecord) async throws {
        let capture = InMemoryCloudTransport()
        try await TestPhone.hub(over: capture).save([plain])
        let batch = try await capture.changes(in: plain.zone, since: nil)
        let sealed = try XCTUnwrap(batch.changed.first)
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = sealed.recordName
        item.record.envelope = sealed.payload
        item.record.clientModifiedAtMs = Int64(sealed.modifiedAt.timeIntervalSince1970 * 1000)
        var save = Relay_V1_Save()
        save.items = [item]
        _ = try await mac.save(save)
    }

    private func names(_ mac: HostedRelayClient, zone: String) async throws -> [String] {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        return try await mac.changes(changes).changed.map(\.name)
    }

    /// The whole link over the fake relay, then the first data read: the hello lands only in `pair/<slot>`, the
    /// Mac's keybox there completes the keys, vouch and promote put the Mac in this account's slots, the session
    /// moves to `data/<mac>` on the same store, a `FORBIDDEN` before the Mac names the phone a reader changes
    /// nothing, and the next pull after the readers sync reads the data zone. One socket for the device throughout.
    func testAPhoneLinksAHubOverAPairingSlotOnTheFakeRelay() async throws {
        let bed = try await makeBed()
        let root = bed.root
        let flow = Task { await root.open(code(bed).url()) }
        await waitUntilParked(bed.linkClock)
        XCTAssertEqual(root.linking.phase, .waiting(macName: "build-box"))
        let slot = try XCTUnwrap(LinkStore(defaults: bed.defaults).pending?.relaySlot)
        let pairZone = "pair/\(slot)"

        let written = try await names(bed.mac, zone: pairZone)
        XCTAssertEqual(written.count, 1, "the hello, and only it, in the pair zone")
        XCTAssertTrue(written.first?.hasPrefix("hello-") ?? false)
        let mailbox = "relay/\(bed.mac.deviceID)/\(bed.phone.deviceID)"
        let mailboxNames = try? await names(bed.mac, zone: mailbox)
        XCTAssertTrue(mailboxNames?.isEmpty ?? true, "no hello in a mailbox")

        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private, linked: true,
            linkedAt: bed.linkClock.start, typingAllowed: false, startSessionsAllowed: true
        )
        try await macSave(bed.mac, zone: pairZone, try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(), modifiedAt: Date()))
        bed.linkClock.release()
        await flow.value

        XCTAssertEqual(root.linking.phase, .linked(macName: "build-box"))
        XCTAssertEqual(root.linking.links.first?.link.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        let slots = try await bed.phone.accountState().macDeviceIds
        XCTAssertEqual(slots, [bed.mac.deviceID], "vouched and promoted")
        let session = try XCTUnwrap(root.env.session(hubID))
        XCTAssertEqual(session.route, .hostedRelay(macDeviceID: bed.mac.deviceID))

        // R5: not a reader yet. The Mac publishes; the phone's pull of data/<mac> is refused.
        let slice = CloudRecordFactory.record(for: SliceRecord(kind: .briefing, id: "today", modifiedAt: Date(), payload: Data("{}".utf8)))
        try await macSave(bed.mac, zone: "data/\(bed.mac.deviceID)", slice)
        _ = await session.refresh(.pull)
        XCTAssertEqual(try briefings(session), 0, "FORBIDDEN: nothing read")
        XCTAssertEqual(root.linking.links.first?.state, .linked, "never a removal")
        XCTAssertNil(root.linking.notice)

        // The Mac's readers sync names the phone: the next pull reads the data zone.
        var readers = Relay_V1_SetHubReaders()
        readers.phoneDeviceIds = [bed.phone.deviceID]
        _ = try await bed.mac.perform(.setHubReaders(readers))
        _ = await session.refresh(.pull)
        XCTAssertEqual(try briefings(session), 1, "read on the next pull")

        XCTAssertEqual(bed.sockets.mostOpenAtOnce, 1, "one socket per device, the pairing and the hub transports on it")
    }

    private func briefings(_ session: HubSession) throws -> Int {
        try session.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?", arguments: [SliceKind.briefing.rawValue]) ?? 0
        }
    }
}
