import CryptoKit
import Foundation
@testable import WatchtowerHostedRelay
@testable import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// One Mac and its phones on both legs, sharing the backend's `ManualRelayClock` (the Go
/// `sim_interop_test.go` `world`). The hub is a `SimHub` over a `SimRelayHubLeg` (a Mac
/// `HostedRelayClient`) and the shared `SimCloudKitLeg`; a paying phone is a `SimPhone` over a
/// `SimRelayPhoneLeg` (the real `HostedRelayTransport` with its own client and store) and the
/// same CloudKit leg; a free phone has CloudKit only. Every relay device is connected, as in
/// Go: the Mac's socket and each paying phone's transport socket are live before `init` and
/// `addPhone` return. Every leg of every device sits in its own `SimFaulty`
/// (`fault(owner, kind)`, owner `hubOwner` or the phone's id). Devices come from fixed seeds:
/// the Mac 1, phones 2, 3, ….
///
/// The twins drive every pass themselves, one at a time (`syncAll`, or a device's `sync`
/// between them); the model actors are never synced concurrently.
final class SimWorld {
    static let origin = "https://relay.example.com"
    static let macSeed: UInt8 = 1
    /// The hub's owner key in `fault(_:_:)`.
    static let hubOwner = "hub"

    let backend: RelayBackend
    let clock: ManualRelayClock
    let cloudKit: SimCloudKitLeg
    let hub: SimHub
    let mac: HostedRelayClient
    private(set) var phones: [SimPhone] = []
    private let hubRelay: SimRelayHubLeg
    private var phoneLegs: [SimRelayPhoneLeg] = []
    private var phoneClients: [String: HostedRelayClient] = [:]
    private var payingPhones: [String] = []
    /// The devices whose socket must be live.
    private var connected: [String] = []
    private var faults: [String: [SimKind: SimFaulty]] = [:]
    private var nextSeed = macSeed + 1

    /// The Mac registered, logged in and connected, on `start` in epoch 1 (the relay, as in Go).
    init(backend: RelayBackend, start: SimKind = .relay) async throws {
        self.backend = backend
        switch backend {
        case .fake(let relay): clock = relay.clock
        }
        cloudKit = SimCloudKitLeg(clock: clock)
        mac = try await Self.client(backend, kind: .mac, seed: Self.macSeed)
        cloudKit.addDataZone(Self.cloudKitData(mac.deviceID))
        hubRelay = SimRelayHubLeg(client: mac, clock: clock)
        let legs = [SimKind.relay: SimFaulty(hubRelay), .cloudkit: SimFaulty(cloudKit)]
        faults[Self.hubOwner] = legs
        hub = SimHub(SimHubConfig(
            id: mac.deviceID, clock: clock, transports: legs, phones: [], current: start,
            dataZone: HostedRelayZones.data(mac: mac.deviceID)))
        await hubRelay.connect()
        connected.append(mac.deviceID)
        await socketsReady()
    }

    /// The server's `/dev` controls.
    var stand: any RelayStandControl {
        switch backend {
        case .fake(let relay): return relay
        }
    }

    /// Links a new phone to the hub. A paying phone registers, pays, is paired with the Mac,
    /// has its transport started (socket live) and starts on the hub's transport with a mailbox
    /// on both legs; a free phone has only its CloudKit mailbox and starts there.
    ///
    /// Pairing names every paying phone added so far as the Mac's readers again (the stand's
    /// `pair` replaces the reader set), so adding one mid-scenario also re-pairs a phone whose
    /// subscription lapsed meanwhile — a scenario about a lapsed phone adds its phones first.
    func addPhone(paying: Bool) async throws -> SimPhone {
        let seed = nextSeed
        nextSeed += 1
        let start = await hub.transport
        let phone: SimPhone
        if paying {
            let client = try await Self.client(backend, kind: .phone, seed: seed)
            let account = try await stand.accountID(ofPhone: client.deviceID)
            try await stand.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
            payingPhones.append(client.deviceID)
            try await stand.pair(mac: mac.deviceID, phones: payingPhones)
            let transport = try HostedRelayTransport(client: client, store: TransportStore.inMemory(), macDeviceID: mac.deviceID)
            let leg = SimRelayPhoneLeg(transport: transport, clock: clock)
            await leg.start()
            phoneLegs.append(leg)
            connected.append(client.deviceID)
            phone = SimPhone(SimPhoneConfig(
                id: client.deviceID, clock: clock,
                transports: wrap(client.deviceID, [.relay: leg, .cloudkit: cloudKit]),
                mailbox: mailboxes(client.deviceID, relay: true), current: start,
                dataZone: HostedRelayZones.data(mac: mac.deviceID)))
            phoneClients[client.deviceID] = client
            await socketsReady()
        } else {
            let id = RelayAuthMessages.deviceID(publicKey: try Self.signer(seed: seed).publicKey)
            phone = SimPhone(SimPhoneConfig(
                id: id, clock: clock, transports: wrap(id, [.cloudkit: cloudKit]), mailbox: mailboxes(id, relay: false),
                current: .cloudkit, dataZone: ""))
        }
        await hub.addPhone(SimPhoneLink(id: phone.id, mailbox: mailboxes(phone.id, relay: paying)))
        phones.append(phone)
        return phone
    }

    /// The fault seam of `owner`'s leg of `kind` (owner `hubOwner` or a phone's id).
    func fault(_ owner: String, _ kind: SimKind) -> SimFaulty? {
        faults[owner]?[kind]
    }

    /// Closes every socket (the twins' tear-down).
    func close() async {
        await hubRelay.close()
        for leg in phoneLegs {
            await leg.close()
        }
    }

    // MARK: - Driving

    /// Syncs the hub, then every phone, one pass at a time, until a whole round makes no
    /// progress (the Go `settle`). Passes never overlap: the twins drive the model serially.
    func syncAll(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            var progress = await hub.sync()
            for phone in phones {
                let moved = await phone.sync()
                progress = progress || moved
            }
            if !progress { return }
        }
        XCTFail("sim: no quiescence after 100 rounds", file: file, line: line)
        throw SimWorldError.noQuiescence
    }

    /// Moves the shared clock.
    func advance(_ duration: Duration) {
        clock.advance(by: duration)
    }

    /// The relay is down for everyone (fake only: `crash`; the stand skips, R15).
    func relayDown() throws {
        try fake("relayDown needs the fake's crash").crash()
    }

    /// The relay is back with the state it had (fake only: `restart`); returns once every
    /// socket is live again.
    func relayUp(file: StaticString = #filePath, line: UInt = #line) async throws {
        try fake("relayUp needs the fake's restart").restart()
        await socketsReady(file: file, line: line)
    }

    /// The phone's subscription ends now (`ENTITLEMENT_EXPIRED` to the phone and to the Mac).
    func expireEntitlement(_ phone: SimPhone) async throws {
        let account = try await stand.accountID(ofPhone: phone.id)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
    }

    /// Waits until at least `count` server controls reached `owner`'s relay connection (held
    /// or not; Go `waitHubControl`) and returns them, untaken. 5 s cap, pumping the clock.
    @discardableResult
    func controlsDelivered(
        to owner: String, count: Int = 1, file: StaticString = #filePath, line: UInt = #line
    ) async -> [SimControl] {
        guard let leg = fault(owner, .relay) else {
            XCTFail("sim: \(owner) has no relay leg", file: file, line: line)
            return []
        }
        await spin(file: file, line: line) {
            if leg.pendingControls().count >= count { return true }
            self.pump()
            return false
        }
        return leg.pendingControls()
    }

    // MARK: - Looking

    /// The names of the live records of the phone's relay mailbox, read by the Mac.
    func relayMailbox(_ phone: SimPhone) async throws -> [String] {
        var changes = Relay_V1_Changes()
        changes.zone = HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.id)
        var live: [String: Bool] = [:]
        while true {
            let page = try await mac.changes(changes)
            for record in page.changed { live[record.name] = !record.deleted }
            for name in page.deleted { live[name] = false }
            changes.sinceSeq = page.newSeq
            if !page.more { break }
        }
        return live.filter(\.value).keys.sorted()
    }

    /// The names of the live records of the phone's CloudKit mailbox.
    func cloudKitMailbox(_ phone: SimPhone) async -> [String] {
        await cloudKit.live(cloudKitZone(phone))
    }

    /// The phone's CloudKit mailbox zone.
    func cloudKitZone(_ phone: SimPhone) -> String {
        Self.cloudKitMailbox(mac: mac.deviceID, phone: phone.id)
    }

    /// The relay client of a paying phone.
    func relayClient(_ phone: SimPhone) -> HostedRelayClient? {
        phoneClients[phone.id]
    }

    // MARK: - Private

    private func mailboxes(_ phoneID: String, relay: Bool) -> [SimKind: String] {
        let zone = Self.cloudKitMailbox(mac: mac.deviceID, phone: phoneID)
        cloudKit.addMailbox(zone)
        var out: [SimKind: String] = [.cloudkit: zone]
        if relay { out[.relay] = HostedRelayZones.mailbox(mac: mac.deviceID, phone: phoneID) }
        return out
    }

    /// Wraps each leg of `owner` in its fault seam.
    private func wrap(_ owner: String, _ legs: [SimKind: any SimTransport]) -> [SimKind: any SimTransport] {
        let wrapped = legs.mapValues { SimFaulty($0) }
        faults[owner] = wrapped
        return wrapped
    }

    /// Waits until every connected device has a live socket on the fake (5 s cap, pumping the
    /// clock through reconnect waits).
    private func socketsReady(file: StaticString = #filePath, line: UInt = #line) async {
        guard case .fake(let relay) = backend else { return }
        let ids = connected
        await spin(file: file, line: line) {
            if relay.locked({ ids.allSatisfy { relay.liveSocket(of: $0) != nil } }) { return true }
            self.pump()
            return false
        }
    }

    /// One wait step: the clock moves to the next short sleep (a reconnect wait or a backoff).
    private func pump() {
        _ = clock.advanceToNextSleeper(shorterThan: .seconds(10))
    }

    private func fake(_ why: String) throws -> FakeHostedRelay {
        switch backend {
        case .fake(let relay): return relay
        // Task 12: case .stand → throw XCTSkip(why)
        }
    }

    /// The Go `ckMailbox`.
    static func cloudKitMailbox(mac: String, phone: String) -> String {
        "ck/\(mac)/\(phone)"
    }

    static func cloudKitData(_ mac: String) -> String {
        "ck/\(mac)"
    }

    static func signer(seed: UInt8) throws -> Ed25519RelaySigner {
        Ed25519RelaySigner(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
    }

    /// A registered, logged-in client of the device of `seed` on `backend`
    /// (`HostedRelayScenarioCase.makeClient`'s construction; a Mac is exempt from attestation on
    /// the fake, R18).
    static func client(_ backend: RelayBackend, kind: Relay_V1_DeviceKind, seed: UInt8) async throws -> HostedRelayClient {
        let signer = try signer(seed: seed)
        let relay: FakeHostedRelay
        switch backend {
        case .fake(let fake): relay = fake
        }
        if kind == .mac, case .enforce(let exempt) = relay.attestMode {
            relay.attestMode = .enforce(exemptDeviceIDs: exempt.union([RelayAuthMessages.deviceID(publicKey: signer.publicKey)]))
        }
        let client = HostedRelayClient(
            origin: try RelayOrigin(origin), signer: signer, kind: kind,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: relay.clock),
            http: relay.http, sockets: relay.sockets, clock: relay.clock
        ) { _ in .milliseconds(20) }
        _ = try await client.register()
        try await client.login()
        return client
    }
}

extension HostedRelayScenarioCase {
    /// A `SimWorld` on this case's backend, its sockets closed at tear-down.
    func simWorld(start: SimKind = .relay) async throws -> SimWorld {
        let world = try await SimWorld(backend: backend, start: start)
        addTeardownBlock { await world.close() }
        return world
    }
}

enum SimWorldError: Error {
    case noQuiescence
}
