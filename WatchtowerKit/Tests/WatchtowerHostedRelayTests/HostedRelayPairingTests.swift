import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Pairing on the relay (R3): `HostedRelayPairing` (`open_pairing`, `promote_pairing`,
/// `close_pairing`, `remove_slot`, `get_account_state`) and the pairing mode of
/// `HostedRelayTransport`, both on `FakeHostedRelay` (Worker `pairing.ts` / `slots.ts`).
final class HostedRelayPairingTests: HostedRelayScenarioCase {
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private var transports: [HostedRelayTransport] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for transport in transports { await transport.stop() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        transports = []
        directories = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var relay: FakeHostedRelay {
        get throws { try requireFake("needs the fake's faults, limits or clock (fake only, R15)") }
    }

    /// A paying phone and a registered Mac that holds no slot yet.
    private func phoneAndMac(phone: UInt8 = 2, mac: UInt8 = 1, paying: Bool = true) async throws -> (HostedRelayClient, HostedRelayClient) {
        let phoneClient = try await makeClient(kind: .phone, seed: phone)
        let macClient = try await makeClient(kind: .mac, seed: mac)
        if paying { try await pay(phoneClient) }
        return (phoneClient, macClient)
    }

    private func storePath() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url.appendingPathComponent("transport.sqlite").path
    }

    private func transport(
        _ session: HostedRelaySession, mac: HostedRelayClient, store: TransportStore, mode: HostedRelayTransportMode
    ) throws -> HostedRelayTransport {
        let transport = try HostedRelayTransport(session: session, store: store, macDeviceID: mac.deviceID, mode: mode)
        transports.append(transport)
        return transport
    }

    private func record(_ name: String, zone: CloudZoneID = .relay, asset: URL? = nil) -> CloudRecord {
        CloudRecord(
            recordName: name, zone: zone, kind: WireKind.envelope, modifiedAt: Self.stamp,
            payload: Data("envelope-\(name)".utf8), assetFileURL: asset)
    }

    /// The Mac's side of the pair zone: the names written there since 0.
    private func macReads(_ mac: HostedRelayClient, _ zone: String) async throws -> [String] {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        return try await mac.changes(changes).changed.map(\.name)
    }

    private func macSave(_ mac: HostedRelayClient, _ zone: String, _ name: String) async throws {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = name
        item.record.envelope = Data(name.utf8)
        var save = Relay_V1_Save()
        save.items = [item]
        _ = try await mac.save(save)
    }

    /// The zones of every `changes` and `save` in the op log, in order.
    private func zonesOf(_ name: String) -> [String] {
        backend.opLog.compactMap { op in
            switch op {
            case .changes(let changes) where name == "changes": return changes.zone
            case .save(let save) where name == "save": return save.items.first?.record.zone
            default: return nil
            }
        }
    }

    private func opCount(_ name: String) -> Int {
        backend.opLog.filter { HostedRelayClient.name($0) == name }.count
    }

    private func assertRefusal(
        _ expected: HostedRelayPairing.Refusal, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("no refusal, expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HostedRelayPairing.Refusal, expected, file: file, line: line)
        }
    }

    // MARK: - Pairing mode

    func testPairingModeMapsBothLanesToThePairZone() async throws {
        let (phone, mac) = try await phoneAndMac()
        let session = HostedRelaySession(client: phone)
        let (slot, _) = try await HostedRelayPairing(session: session).open(mac: mac.deviceID)
        let zone = HostedRelayZones.pair(slot: slot)
        let pairing = try transport(session, mac: mac, store: TransportStore.inMemory(), mode: .pairing(slot: slot))

        try await pairing.save([record("hello-p")])
        try await pairing.pull()
        XCTAssertEqual(zonesOf("save"), [zone], "the hello goes into the pair zone")
        XCTAssertEqual(Set(zonesOf("changes")), [zone], "both lanes pull the pair zone")
        XCTAssertEqual(zonesOf("changes").count, 2, "one pull per lane")

        // The data lane stays read only (the relay would answer FORBIDDEN too).
        let outcomes = try await pairing.save([ConditionalSave(record: record("keybox-x", zone: .data), expect: .none)])
        XCTAssertEqual(outcomes, [.refused(.permanent(code: "forbidden"))])
        XCTAssertEqual(zonesOf("save").count, 1, "a data-lane write never reaches the relay")
    }

    func testAHelloAndAKeyboxRoundTripThroughThePairZone() async throws {
        let (phone, mac) = try await phoneAndMac()
        let session = HostedRelaySession(client: phone)
        let (slot, expiresAt) = try await HostedRelayPairing(session: session).open(mac: mac.deviceID)
        XCTAssertEqual(slot.count, 26)
        XCTAssertGreaterThan(expiresAt, backend.clock.now())
        let zone = HostedRelayZones.pair(slot: slot)
        let store = try TransportStore.inMemory()
        let pairing = try transport(session, mac: mac, store: store, mode: .pairing(slot: slot))

        try await pairing.save([record("hello-p")])
        await pairing.sendNow()
        // The Mac (as the Go hub's `OnPairingOpened`) reads the hello and answers with a keybox.
        let read = try await macReads(mac, zone)
        XCTAssertEqual(read, ["hello-p"])
        try await macSave(mac, zone, "keybox-p")

        try await pairing.pull()
        let data = try store.changes(in: .data, since: nil)
        XCTAssertTrue(data.changed.contains { $0.recordName == "keybox-p" && $0.payload == Data("keybox-p".utf8) })
        let relayLane = try store.changes(in: .relay, since: nil)
        XCTAssertTrue(relayLane.changed.contains { $0.recordName == "keybox-p" }, "the relay lane reads the same zone")
    }

    func testAttachmentsAreRefusedInPairingMode() async throws {
        let (phone, mac) = try await phoneAndMac()
        let session = HostedRelaySession(client: phone)
        let (slot, _) = try await HostedRelayPairing(session: session).open(mac: mac.deviceID)
        let pairing = try transport(session, mac: mac, store: TransportStore.inMemory(), mode: .pairing(slot: slot))
        let file = try URL(fileURLWithPath: storePath()).deletingLastPathComponent().appendingPathComponent("asset")
        try Data("asset".utf8).write(to: file)

        let outcomes = try await pairing.save([ConditionalSave(record: record("hello-a", asset: file), expect: .none)])
        XCTAssertEqual(outcomes, [.refused(.permanent(code: "forbidden"))])
        XCTAssertEqual(opCount("createUpload"), 0, "refused before any request")
        XCTAssertEqual(opCount("save"), 0)
    }

    func testOneStoreFromPairingToHubModeKeepsItsBufferTokens() async throws {
        let (phone, mac) = try await phoneAndMac()
        let session = HostedRelaySession(client: phone)
        let pairer = HostedRelayPairing(session: session)
        let (slot, _) = try await pairer.open(mac: mac.deviceID)
        let pairZone = HostedRelayZones.pair(slot: slot)
        let path = try storePath()
        let store = try TransportStore(path: path)

        let pairing = try transport(session, mac: mac, store: store, mode: .pairing(slot: slot))
        try await pairing.save([record("hello-p")])
        try await macSave(mac, pairZone, "keybox-p")
        try await pairing.pull()
        let afterPairing = try store.changes(in: .data, since: nil)
        XCTAssertEqual(afterPairing.changed.map(\.recordName).sorted(), ["hello-p", "keybox-p"])
        // Queued for the pair zone and never sent: it must not reach the mailbox later.
        try await pairing.save([record("hello-late")])
        await pairing.stop()

        try await pairer.promote(slot: slot)
        let dataZone = HostedRelayZones.data(mac: mac.deviceID)
        for index in 0..<4 { try await macSave(mac, dataZone, "d\(index)") }
        var readers = Relay_V1_SetHubReaders()
        readers.phoneDeviceIds = [phone.deviceID]
        _ = try await mac.perform(.setHubReaders(readers))

        // The same store, now in hub mode: the data zone is read from its start, not from the
        // pair zone's cursor, and the buffer's tokens keep counting up.
        let hub = try transport(session, mac: mac, store: store, mode: .hub)
        try await hub.pull()
        XCTAssertEqual(backend.opLog.compactMap { op -> UInt64? in
            guard case .changes(let changes) = op, changes.zone == dataZone else { return nil }
            return changes.sinceSeq
        }.first, 0, "a new zone starts at 0")
        let afterHub = try store.changes(in: .data, since: afterPairing.newToken)
        XCTAssertEqual(afterHub.changed.map(\.recordName), ["d0", "d1", "d2", "d3"])
        XCTAssertEqual(Set(afterHub.deletedRecordNames), ["hello-p", "keybox-p"], "the pair zone's records leave the buffer")
        XCTAssertGreaterThan(afterHub.newToken.value, afterPairing.newToken.value, "one monotonic buffer")
        XCTAssertEqual(try store.relayCursor(zone: .data), 4)
        XCTAssertFalse(try store.relayResyncPending(.data))
        XCTAssertFalse(try store.relayResyncPending(.relay))
        XCTAssertFalse(try store.isPending(recordName: "hello-late", zone: .relay))
        XCTAssertFalse(backend.opLog.contains { op in
            guard case .save(let save) = op else { return false }
            return save.items.contains { $0.record.name == "hello-late" }
        }, "a write queued for the pair zone is dropped with the zone")
    }

    // MARK: - Slots

    func testSlotsFullIsRefusedBeforeOpenPairing() async throws {
        let phone = try await makeClient(kind: .phone, seed: 2)
        try await pay(phone)
        var macs: [String] = []
        for seed in UInt8(10)..<13 {
            let mac = try await makeClient(kind: .mac, seed: seed)
            try await stand.pair(mac: mac.deviceID, phones: [phone.deviceID])
            macs.append(mac.deviceID)
        }
        let fourth = try await makeClient(kind: .mac, seed: 13)
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))

        let state = try await pairer.accountState()
        XCTAssertTrue(state.paying)
        XCTAssertEqual(state.macs.sorted(), macs.sorted())
        await assertRefusal(.slotsFull(macs: macs.sorted())) { _ = try await pairer.open(mac: fourth.deviceID) }
        XCTAssertEqual(opCount("openPairing"), 0, "refused before open_pairing")

        // A Mac already in the slots may pair again (a re-link).
        _ = try await pairer.open(mac: macs[0])
        XCTAssertEqual(opCount("openPairing"), 1)
    }

    func testNotPayingIsRefusedByOpenPairing() async throws {
        let (phone, mac) = try await phoneAndMac(paying: false)
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))
        let state = try await pairer.accountState()
        XCTAssertFalse(state.paying)
        await assertRefusal(.notPaying) { _ = try await pairer.open(mac: mac.deviceID) }
        XCTAssertEqual(opCount("openPairing"), 1, "the relay is the judge")
    }

    func testPromoteAfterExpiryIsPairingExpired() async throws {
        _ = try relay
        let (phone, mac) = try await phoneAndMac()
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))
        let (slot, _) = try await pairer.open(mac: mac.deviceID)
        manualClock?.advance(by: .seconds(601))
        await assertRefusal(.pairingExpired) { try await pairer.promote(slot: slot) }
        let macsAfter = try await pairer.accountState().macs
        XCTAssertEqual(macsAfter, [])
    }

    func testReplacementLimitOnPromote() async throws {
        var limits = try relay.limits
        limits.slotReplacementsPer30Days = 0
        try relay.limits = limits
        let phone = try await makeClient(kind: .phone, seed: 2)
        try await pay(phone)
        let first = try await makeClient(kind: .mac, seed: 1)
        let second = try await makeClient(kind: .mac, seed: 3)
        try await stand.pair(mac: first.deviceID, phones: [phone.deviceID])
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))

        try await pairer.removeSlot(mac: first.deviceID)
        let afterRemove = try await pairer.accountState().macs
        XCTAssertEqual(afterRemove, [])
        // A repeat within 24 h is done too, and a Mac never slotted is NOT_FOUND, also done (R14).
        try await pairer.removeSlot(mac: first.deviceID)
        try await pairer.removeSlot(mac: second.deviceID)

        let (slot, _) = try await pairer.open(mac: second.deviceID)
        await assertRefusal(.replacementLimit) { try await pairer.promote(slot: slot) }
        let macsAfter = try await pairer.accountState().macs
        XCTAssertEqual(macsAfter, [])
    }

    func testSlotLimitOnPromoteNamesTheMacs() async throws {
        let phone = try await makeClient(kind: .phone, seed: 2)
        try await pay(phone)
        let late = try await makeClient(kind: .mac, seed: 20)
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))
        // The slot opens while two Macs hold slots; a third fills them before promote.
        var macs: [String] = []
        for seed in UInt8(21)..<23 {
            let mac = try await makeClient(kind: .mac, seed: seed)
            try await stand.pair(mac: mac.deviceID, phones: [phone.deviceID])
            macs.append(mac.deviceID)
        }
        let (slot, _) = try await pairer.open(mac: late.deviceID)
        let third = try await makeClient(kind: .mac, seed: 23)
        try await stand.pair(mac: third.deviceID, phones: [phone.deviceID])
        macs.append(third.deviceID)
        await assertRefusal(.slotsFull(macs: macs.sorted())) { try await pairer.promote(slot: slot) }
    }

    func testCloseIsBestEffort() async throws {
        let (phone, mac) = try await phoneAndMac()
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))
        let (slot, _) = try await pairer.open(mac: mac.deviceID)
        await pairer.close(slot: slot)
        do {
            try await pairer.promote(slot: slot)
            XCTFail("a closed slot was promoted")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, .server(code: .notFound, retryAfter: nil))
        }
        // Closing again (NOT_FOUND) or into a refusal neither throws nor retries.
        await pairer.close(slot: slot)
        try relay.failNext("closePairing", with: .forbidden)
        await pairer.close(slot: slot)
        XCTAssertEqual(opCount("closePairing"), 3)
    }

    func testASecondOpenForTheSameMacReplacesTheSlot() async throws {
        let (phone, mac) = try await phoneAndMac()
        let pairer = HostedRelayPairing(session: HostedRelaySession(client: phone))
        let (first, _) = try await pairer.open(mac: mac.deviceID)
        let (second, _) = try await pairer.open(mac: mac.deviceID)
        XCTAssertNotEqual(first, second)
        do {
            try await pairer.promote(slot: first)
            XCTFail("the replaced slot was promoted")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, .server(code: .notFound, retryAfter: nil))
        }
        try await pairer.promote(slot: second)
        let macsAfter = try await pairer.accountState().macs
        XCTAssertEqual(macsAfter, [mac.deviceID])
    }
}
