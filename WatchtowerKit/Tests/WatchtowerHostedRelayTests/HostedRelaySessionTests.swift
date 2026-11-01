import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// `HostedRelaySession` on `FakeHostedRelay` (R2): every relay object of the phone shares one
/// socket, because the relay displaces an older socket of the same device (close 1001 after
/// `GoingAway`). The phone's client counts its dials and its displacements.
final class HostedRelaySessionTests: HostedRelayScenarioCase {
    private var transports: [HostedRelayTransport] = []
    private var eventLogs: [TransportEventLog] = []
    private var probes: [(HostedRelaySession, Probe)] = []
    private var readers: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for transport in transports { await transport.stop() }
        for (session, probe) in probes { await session.detach(owner: ObjectIdentifier(probe)) }
        for log in eventLogs { log.cancel() }
        for reader in readers { reader.cancel() }
        transports = []
        eventLogs = []
        probes = []
        readers = []
        try await super.tearDown()
    }

    // MARK: - Tests

    func testTwoHubsAndAPairingSlotShareOneSocket() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        await first.start()
        await second.start()
        let slot = HostedRelayZones.pair(slot: "slot-a")
        _ = await probe(session, zones: [slot])

        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] } + [slot]
        await eventually { Set(zones).isSubset(of: self.subscribed()) }
        XCTAssertEqual(tally.dials, 1, "one socket for two hubs and a pairing slot")
        XCTAssertEqual(tally.displacements, 0)
    }

    func testAZoneEventReachesOnlyItsTransport() async throws {
        let (phone, _, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let zoneA = dataZone(macs[0])
        let zoneB = dataZone(macs[1])
        let ownerA = await probe(session, zones: [zoneA])
        let ownerB = await probe(session, zones: [zoneB])
        await eventually { ownerA.zoneEvents.contains { $0.zone == zoneA } && ownerB.zoneEvents.contains { $0.zone == zoneB } }

        let seqA = try await save(macs[0], zoneA, "for-a")
        await eventually { ownerA.zoneEvents.contains { $0 == ZoneEvent(zone: zoneA, seq: seqA) } }
        // B's inbox is in order: once B has its own later event, an event of A's zone would be before it.
        let seqB = try await save(macs[1], zoneB, "for-b")
        await eventually { ownerB.zoneEvents.contains { $0 == ZoneEvent(zone: zoneB, seq: seqB) } }

        XCTAssertEqual(ownerA.zoneEvents.map(\.zone).filter { $0 != zoneA }, [], "A sees its zone only")
        XCTAssertEqual(ownerB.zoneEvents.map(\.zone).filter { $0 != zoneB }, [], "B sees its zone only")
        XCTAssertEqual(ownerA.zoneEvents.filter { $0.zone == zoneA && $0.seq == 0 }.count, 1, "the connect's marker once")
        XCTAssertEqual(ownerB.zoneEvents.filter { $0.zone == zoneB && $0.seq == 0 }.count, 1, "the connect's marker once")
    }

    func testRemovingATransportKeepsTheOthersSubscribed() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let store = try TransportStore.inMemory()
        let second = try transport(session, mac: macs[1], store: store)
        await first.start()
        await second.start()
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }

        await first.stop()
        try await save(macs[1], dataZone(macs[1]), "after-the-stop")
        await eventually {
            (try? store.changes(in: .data, since: nil).changed.map(\.recordName))?.contains("after-the-stop") == true
        }
        XCTAssertEqual(tally.dials, 1, "the socket stayed open")
        let connection = await session.connection
        XCTAssertNotNil(connection)
    }

    func testTheLastDetachClosesTheSocket() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        await first.start()
        await second.start()
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }
        let open = await session.connection
        let connection = try XCTUnwrap(open)

        await first.stop()
        let afterFirst = await session.connection
        XCTAssertTrue(afterFirst === connection, "another owner is attached")
        XCTAssertTrue(connection.isLive)

        await second.stop()
        let afterLast = await session.connection
        XCTAssertNil(afterLast)
        XCTAssertFalse(connection.isLive, "closed")
        XCTAssertEqual(tally.dials, 1)
    }

    func testAReconnectResubscribesTheUnion() async throws {
        let relay = try requireFake("displaces the phone's socket (fake only, R15)")
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        await first.start()
        await second.start()
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }

        let mark = backend.opLog.count
        relay.displace(deviceID: phone.deviceID)
        await eventually { Set(zones).isSubset(of: self.subscribed(after: mark)) }
        XCTAssertEqual(tally.dials, 2, "one redial")
    }

    func testAccountControlsGoToTheSession() async throws {
        let (phone, _, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let accountEvents = collect(session.events)
        let marker = await probe(session, zones: [])
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        let firstLog = await log(first)
        let secondLog = await log(second)
        await first.start()
        await second.start()
        await eventually { marker.events.contains(.connected) }

        let account = try await stand.accountID(ofPhone: phone.deviceID)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
        await eventually { accountEvents.events.contains(.control(kind: .entitlementExpired, detail: "")) }
        XCTAssertEqual(accountEvents.events.filter { $0 == .control(kind: .entitlementExpired, detail: "") }.count, 1, "once")
        for log in [firstLog, secondLog] {
            XCTAssertFalse(log.relayEvents.contains { if case .control = $0 { true } else { false } }, "not on a transport")
        }
        XCTAssertTrue(firstLog.relayEvents.contains(.reachable(true)), "each transport keeps its reachability")
        XCTAssertTrue(secondLog.relayEvents.contains(.reachable(true)))
    }

    func testDisplacementNeverLoops() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        async let started: Void = first.start()
        async let alsoStarted: Void = second.start()
        _ = await (started, alsoStarted)
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }
        // Give a displacement loop the reconnect waits it would need.
        for _ in 0..<10 {
            pump()
            await Task.yield()
        }
        XCTAssertEqual(tally.displacements, 0, "no 1001 from the relay")
        XCTAssertEqual(tally.dials, 1)
    }

    // MARK: - Helpers

    /// Dials and displacements (`GoingAway`) of one client.
    final class SocketTally: Sendable {
        private let counts = OSAllocatedUnfairLock(initialState: (dials: 0, displacements: 0))

        var dials: Int {
            counts.withLock { $0.dials }
        }

        var displacements: Int {
            counts.withLock { $0.displacements }
        }

        func dialed() {
            counts.withLock { $0.dials += 1 }
        }

        func displaced() {
            counts.withLock { $0.displacements += 1 }
        }
    }

    struct CountingDialer: RelaySocketDialer {
        let base: any RelaySocketDialer
        let tally: SocketTally

        func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
            tally.dialed()
            return try await base.dial(url, headers: headers)
        }
    }

    struct ZoneEvent: Equatable {
        let zone: String
        let seq: UInt64
    }

    /// An owner that records what the session routes to it.
    final class Probe: Sendable {
        private let received = OSAllocatedUnfairLock<[HostedRelayClientEvent]>(initialState: [])

        var events: [HostedRelayClientEvent] {
            received.withLock { $0 }
        }

        var zoneEvents: [ZoneEvent] {
            events.compactMap { event in
                guard case let .zoneChanged(zone, seq) = event else { return nil }
                return ZoneEvent(zone: zone, seq: seq)
            }
        }

        func record(_ event: HostedRelayClientEvent) {
            received.withLock { $0.append(event) }
        }
    }

    /// Collects a stream of relay events.
    final class EventCollector: Sendable {
        private let received = OSAllocatedUnfairLock<[HostedRelayEvent]>(initialState: [])

        var events: [HostedRelayEvent] {
            received.withLock { $0 }
        }

        func record(_ event: HostedRelayEvent) {
            received.withLock { $0.append(event) }
        }
    }

    /// A paying phone (seed 2) whose dials are counted, paired with the Macs of `seeds`.
    private func paired(macs seeds: [UInt8]) async throws -> (HostedRelayClient, SocketTally, [HostedRelayClient]) {
        let tally = SocketTally()
        let signer = try backend.signer(seed: 2)
        let clock = backend.clock
        let phone = HostedRelayClient(
            origin: try backend.origin,
            signer: signer,
            kind: .phone,
            attestor: RelayAttestor(attest: fakeAttest(seed: 2), keys: InMemoryAppAttestKeyStore(), clock: clock),
            http: backend.http,
            sockets: CountingDialer(base: backend.sockets, tally: tally),
            clock: clock,
            backoff: Self.quickBackoff
        ) { tally.displaced() }
        _ = try await phone.register()
        try await phone.login()
        try await pay(phone)
        var macs: [HostedRelayClient] = []
        for seed in seeds {
            let mac = try await makeClient(kind: .mac, seed: seed)
            try await stand.pair(mac: mac.deviceID, phones: [phone.deviceID])
            macs.append(mac)
        }
        return (phone, tally, macs)
    }

    private func transport(
        _ session: HostedRelaySession, mac: HostedRelayClient, store: TransportStore? = nil
    ) throws -> HostedRelayTransport {
        let transport = try HostedRelayTransport(session: session, store: store ?? TransportStore.inMemory(), macDeviceID: mac.deviceID)
        transports.append(transport)
        return transport
    }

    private func log(_ transport: HostedRelayTransport) async -> TransportEventLog {
        let log = TransportEventLog()
        await log.attach(to: transport)
        eventLogs.append(log)
        return log
    }

    private func probe(_ session: HostedRelaySession, zones: [String]) async -> Probe {
        let probe = Probe()
        probes.append((session, probe))
        await session.attach(owner: ObjectIdentifier(probe), zones: zones) { event in probe.record(event) }
        return probe
    }

    private func collect(_ stream: AsyncStream<HostedRelayEvent>) -> EventCollector {
        let collector = EventCollector()
        let reader = Task {
            for await event in stream { collector.record(event) }
        }
        readers.append(reader)
        return collector
    }

    private func dataZone(_ mac: HostedRelayClient) -> String {
        HostedRelayZones.data(mac: mac.deviceID)
    }

    private func mailbox(_ mac: HostedRelayClient, _ phone: HostedRelayClient) -> String {
        HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.deviceID)
    }

    /// Every zone subscribed on a socket after the first `after` ops.
    private func subscribed(after: Int = 0) -> Set<String> {
        Set(backend.opLog.dropFirst(after).flatMap { op -> [String] in
            guard case .subscribe(let subscribe) = op else { return [] }
            return subscribe.zones
        })
    }
}
