import CryptoKit
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

final class SecureTransportTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Builders

    private func slice(_ kind: SliceKind = .target, id: String = "1", notifyLevel: String? = nil) -> CloudRecord {
        CloudRecord(
            recordName: kind.recordName(id: id), zone: .data, kind: kind.rawValue, modifiedAt: stamp,
            payload: Data("{\"id\":\"\(id)\"}".utf8), notifyLevel: notifyLevel)
    }

    private func action(_ id: String = "a1", deviceID: UUID = TestE2E.deviceID, status: String = "pending") -> CloudRecord {
        CloudRecord(
            recordName: "action-\(id)", zone: .relay, kind: RelayRecordKind.action.rawValue, modifiedAt: stamp,
            payload: Data("{\"device_id\":\"\(deviceID.uuidString)\",\"id\":\"\(id)\",\"status\":\"\(status)\"}".utf8))
    }

    private final class Rejections: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(wireName: String, reason: String)] = []
        var values: [(wireName: String, reason: String)] { lock.withLock { items } }
        func append(_ name: String, _ reason: String) { lock.withLock { items.append((name, reason)) } }
    }

    private func hubTransport(
        inner: any CloudSyncTransport & Sendable,
        keys: TestHubKeyProvider = TestE2E.hub(),
        names: (any WireNameIndex)? = nil,
        rejections: Rejections? = nil
    ) -> SecureTransport {
        SecureTransport(
            inner: inner, keys: keys, rollback: InMemoryRollbackGuard(), names: names,
            onRejected: rejections.map { box in { name, reason in box.append(name, reason) } })
    }

    private func phoneTransport(
        inner: any CloudSyncTransport & Sendable,
        keys: PhoneKeyProvider? = nil,
        rejections: Rejections? = nil
    ) throws -> SecureTransport {
        SecureTransport(
            inner: inner, keys: try keys ?? TestE2E.phone(), rollback: InMemoryRollbackGuard(),
            onRejected: rejections.map { box in { name, reason in box.append(name, reason) } })
    }

    private func isBase32Name(_ name: String) -> Bool {
        name.count == 26 && name.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) }
    }

    // MARK: - Sealing and naming

    func testHubSealsDataRecordsUnderOpaqueNamesWithAConstantWireKind() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)

        try await hub.save([slice(.ownerAsk, id: "42", notifyLevel: "urgent")])

        let wire = try await inner.changes(in: .data, since: nil).changed
        XCTAssertEqual(wire.count, 1)
        let record = try XCTUnwrap(wire.first)
        XCTAssertTrue(isBase32Name(record.recordName), record.recordName)
        XCTAssertEqual(record.kind, WireKind.envelope)
        XCTAssertNil(record.notifyLevel, "F28: the level rides in the frame, never on the wire record")
        XCTAssertEqual(record.modifiedAt, stamp, "spec §5: modifiedAt stays plaintext")
        XCTAssertNil(record.sealed)
        XCTAssertNil(record.asset)
        let envelope = try Envelope.parse(record.payload)
        XCTAssertEqual(envelope.header.envelopeClass, .data)
        XCTAssertTrue(envelope.header.flags.contains(.signed))
        XCTAssertEqual(envelope.header.senderID, TestE2E.hubID)

        // The replica's read path: the hub signature verifies and the frame carries kind, plain name and level.
        let opened = try EnvelopeSealer.openSymmetric(
            record.payload, accepting: [.data], context: EnvelopeContext(zone: .data, wireName: record.recordName),
            verifier: TestE2E.hubSigningKey.publicKey) { _ in TestE2E.dataKey(epoch: 1) }
        XCTAssertEqual(opened.frame.kind, "owner_ask")
        XCTAssertEqual(opened.frame.id, "owner_ask-42")
        XCTAssertEqual(opened.frame.notifyLevel, "urgent")
        XCTAssertEqual(record.recordName, try hub.wireName(plain: "owner_ask-42", zone: .data))
    }

    func testHeartbeatKeyboxAndHelloKeepKeyFreeNames() async throws {
        let inner = InMemoryCloudTransport()
        let hubKeys = TestE2E.hub()
        let hub = hubTransport(inner: inner, keys: hubKeys)
        let heartbeat = CloudRecord(
            recordName: HeartbeatPayload.recordName, zone: .data, kind: SliceKind.heartbeat.rawValue,
            modifiedAt: stamp, payload: Data("{}".utf8))
        let grant = CloudRecord(
            recordName: SliceKind.deviceGrant.recordName(id: TestE2E.deviceID.uuidString), zone: .data,
            kind: SliceKind.deviceGrant.rawValue, modifiedAt: stamp, payload: Data("{}".utf8))
        try await hub.save([heartbeat, grant])

        let names = try await inner.changes(in: .data, since: nil).changed.map(\.recordName)
        XCTAssertEqual(names, ["heartbeat", "keybox-\(TestE2E.deviceID.uuidString)"])
        let keybox = try await inner.changes(in: .data, since: nil).changed[1]
        XCTAssertEqual(try Envelope.parse(keybox.payload).header.envelopeClass, .keybox)
        let heartbeatWire = try await inner.changes(in: .data, since: nil).changed[0]
        XCTAssertEqual(try Envelope.parse(heartbeatWire.payload).header.envelopeClass, .data)

        let phoneInner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: phoneInner)
        let helloRecord = CloudRecord(
            recordName: "hello-\(TestE2E.deviceID.uuidString)", zone: .relay, kind: RelayRecordKind.hello.rawValue,
            modifiedAt: stamp, payload: Data("{}".utf8))
        try await phone.save([helloRecord])
        let helloBatch = try await phoneInner.changes(in: .relay, since: nil)
        let hello = try XCTUnwrap(helloBatch.changed.first)
        XCTAssertEqual(hello.recordName, "hello-\(TestE2E.deviceID.uuidString)")
        XCTAssertEqual(try Envelope.parse(hello.payload).header.envelopeClass, .hello)

        XCTAssertEqual(try hub.wireName(plain: "heartbeat", zone: .data), "heartbeat")
        let grantName = await hub.plainName(forWire: "keybox-\(TestE2E.deviceID.uuidString)")
        XCTAssertEqual(grantName, "device_grant-\(TestE2E.deviceID.uuidString)")
    }

    func testAKeyboxForADeviceWithoutARecipientThrows() async throws {
        let hub = hubTransport(inner: InMemoryCloudTransport())
        let stranger = UUID()
        let grant = CloudRecord(
            recordName: SliceKind.deviceGrant.recordName(id: stranger.uuidString), zone: .data,
            kind: SliceKind.deviceGrant.rawValue, modifiedAt: stamp, payload: Data("{}".utf8))
        do {
            try await hub.save([grant])
            XCTFail("expected noKeyboxRecipient")
        } catch let error as SecureTransportError {
            XCTAssertEqual(error, .noKeyboxRecipient("device_grant-\(stranger.uuidString)"))
        }
    }

    func testDataZoneReadsPassThroughUntouched() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)
        try await hub.save([slice(.target, id: "7")])
        let raw = try await inner.changes(in: .data, since: nil)

        let phone = try phoneTransport(inner: inner)
        let read = try await phone.changes(in: .data, since: nil)

        XCTAssertEqual(read, raw, "the replica opens DataZone envelopes on read; the transport hands them over as is")
    }

    func testDeleteMapsPlainNamesToWireNames() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)
        try await hub.save([slice(.target, id: "7")])
        let wire = try hub.wireName(plain: "target-7", zone: .data)

        try await hub.delete(recordNames: ["target-7", "heartbeat"], in: .data)

        let batch = try await inner.changes(in: .data, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertEqual(batch.deletedRecordNames, [wire, "heartbeat"])
    }

    func testSaveSealedSendsStoredBytesUnchanged() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        let sealed = try await phone.seal(action())

        try await phone.saveSealed([sealed])
        try await phone.saveSealed([sealed])

        // Event 1 is the first send, event 2 the re-send: both carry the stored bytes.
        let latest = try await inner.changes(in: .relay, since: nil).changed
        let second = try await inner.changes(in: .relay, since: CloudChangeToken(value: 1)).changed
        XCTAssertEqual(latest, [sealed])
        XCTAssertEqual(second.map(\.payload), [sealed.payload], "byte for byte: a deliberate re-send is not a new envelope")
    }

    func testSignalRecordsPassThroughUnsealed() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)
        let signal = CloudRecord(
            recordName: "sig-abcdefghijklmnopqrstuvwxyz", zone: .data, kind: WireKind.signal,
            modifiedAt: stamp, payload: Data())

        try await hub.save([signal])
        let saved = try await inner.changes(in: .data, since: nil).changed
        XCTAssertEqual(saved, [signal])
        let read = try await hub.changes(in: .data, since: nil).changed
        XCTAssertEqual(read, [signal])

        try await hub.delete(recordNames: [signal.recordName], in: .data)
        let deleted = try await inner.changes(in: .data, since: nil).deletedRecordNames
        XCTAssertEqual(deleted, [signal.recordName])
    }

    func testPlainNameForWireConsultsThePersistedIndexFirst() async throws {
        struct Index: WireNameIndex {
            func plainName(forWire wireName: String) -> String? { wireName == "persisted" ? "target-earlier" : nil }
        }
        let hub = hubTransport(inner: InMemoryCloudTransport(), names: Index())
        try await hub.save([slice(.target, id: "9")])
        let wire = try hub.wireName(plain: "target-9", zone: .data)

        let persisted = await hub.plainName(forWire: "persisted")
        let sealedHere = await hub.plainName(forWire: wire)
        let unknown = await hub.plainName(forWire: "neverseen")
        XCTAssertEqual(persisted, "target-earlier")
        XCTAssertEqual(sealedHere, "target-9", "sealed in this process")
        XCTAssertNil(unknown)
    }

    // MARK: - Relay round trip

    func testPhoneActionRoundTripsToTheHubAndTheEchoBack() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        let hub = hubTransport(inner: inner)
        let request = action()

        try await phone.save([request])
        let wireName = try phone.wireName(for: request)
        XCTAssertTrue(isBase32Name(wireName))

        let received = try await hub.changes(in: .relay, since: nil)
        XCTAssertEqual(received.changed.count, 1)
        let opened = try XCTUnwrap(received.changed.first)
        XCTAssertEqual(opened.recordName, "action-a1")
        XCTAssertEqual(opened.kind, "action")
        XCTAssertEqual(opened.payload, request.payload)
        XCTAssertEqual(opened.sealed?.senderID, TestE2E.deviceID)
        XCTAssertEqual(opened.sealed?.wireName, wireName)
        XCTAssertEqual(opened.sealed?.envelopeClass, .relayToHub)

        let echo = CloudRecord(
            recordName: opened.recordName, zone: .relay, kind: opened.kind, modifiedAt: stamp.addingTimeInterval(5),
            payload: action(status: "applied").payload, sealed: opened.sealed)
        try await hub.save([echo])

        let back = try await phone.changes(in: .relay, since: received.newToken)
        XCTAssertEqual(back.changed.count, 1)
        let echoed = try XCTUnwrap(back.changed.first)
        XCTAssertEqual(echoed.recordName, "action-a1")
        XCTAssertEqual(echoed.payload, echo.payload)
        XCTAssertEqual(echoed.sealed?.senderID, TestE2E.hubID)
        XCTAssertEqual(echoed.sealed?.envelopeClass, .relayToPhone)
    }

    func testThePhoneOpensItsOwnRelayRecords() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        try await phone.save([action()])

        let mine = try await phone.changes(in: .relay, since: nil).changed
        XCTAssertEqual(mine.map(\.recordName), ["action-a1"])
        XCTAssertEqual(mine.first?.sealed?.senderID, TestE2E.deviceID)
    }

    func testAnUnknownSendersRelayRecordIsDroppedAndReported() async throws {
        let inner = InMemoryCloudTransport()
        let stranger = try phoneTransport(inner: inner, keys: TestE2E.stranger())
        try await stranger.save([action("x1", deviceID: TestE2E.strangerDeviceID)])
        let rejections = Rejections()
        let hub = hubTransport(inner: inner, rejections: rejections)

        let batch = try await hub.changes(in: .relay, since: nil)
        _ = try await hub.changes(in: .relay, since: nil)

        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertEqual(rejections.values.count, 1, "reported once per wire name")
        XCTAssertEqual(batch.newToken.value, 1, "the token still advances past a dropped record")
    }

    func testARolledBackRelayRecordIsIgnoredAndAnIdenticalRedeliveryPasses() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner, keys: TestE2E.phone(firstSeq: 5))
        let hub = hubTransport(inner: inner)
        let version1 = try await phone.seal(action(status: "pending"))
        let version2 = try await phone.seal(action(status: "cancelled"))
        XCTAssertEqual(try Envelope.parse(version1.payload).header.seq, 5)
        XCTAssertEqual(try Envelope.parse(version2.payload).header.seq, 6)

        try await inner.save([version1, version2])
        let first = try await hub.changes(in: .relay, since: nil)
        XCTAssertEqual(first.changed.map(\.payload), [action(status: "cancelled").payload])

        try await inner.save([version1])
        let rolledBack = try await hub.changes(in: .relay, since: first.newToken)
        XCTAssertTrue(rolledBack.changed.isEmpty, "an older (epoch, seq) of the same record is ignored")

        try await inner.save([version2])
        let redelivered = try await hub.changes(in: .relay, since: rolledBack.newToken)
        XCTAssertEqual(redelivered.changed.map(\.payload), [action(status: "cancelled").payload], ".same passes")
    }

    func testLockedKeysMakeChangesThrowSoTheTokenIsKept() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)
        try await hub.save([action()])
        let store = try TestE2E.phoneStore()
        let phone = try phoneTransport(inner: inner, keys: TestE2E.phone(store: store))
        store.isLocked = true

        do {
            _ = try await phone.changes(in: .relay, since: nil)
            XCTFail("expected keysUnavailable")
        } catch let error as SecureTransportError {
            XCTAssertEqual(error, .keysUnavailable)
        }

        store.isLocked = false
        let batch = try await phone.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["action-a1"], "replayed after unlock")
    }

    func testThePreviousEpochIsAcceptedOnlyWhileTheProviderSaysSo() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        let hubKeys = TestE2E.hub(epoch: 2)
        let hub = hubTransport(inner: inner, keys: hubKeys)

        try await phone.save([action("e1")])
        let accepted = try await hub.changes(in: .relay, since: nil)
        XCTAssertEqual(accepted.changed.map(\.recordName), ["action-e1"])
        XCTAssertEqual(accepted.changed.first?.sealed?.epoch, 1)

        hubKeys.acceptsPreviousEpoch = false
        try await phone.save([action("e2")])
        let refused = try await hub.changes(in: .relay, since: accepted.newToken)
        XCTAssertTrue(refused.changed.isEmpty, "D10: the previous epoch only within the provider's window")
    }

    // MARK: - F1 compaction and sweep

    private actor SpyInner: CompactingTransport, SweepingTransport {
        let inner = InMemoryCloudTransport()
        private(set) var compacted: [(CloudZoneID, Int)] = []
        private(set) var swept: [(CloudZoneID, Int)] = []

        func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {
            try await inner.delete(recordNames: recordNames, in: zone)
        }
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            try await inner.changes(in: zone, since: token)
        }
        func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
            compacted.append((zone, token.value))
        }
        func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) async throws -> Int {
            swept.append((zone, token.value))
            return 3
        }
    }

    func testCompactionAndSweepReachTheInnerTransport() async throws {
        let spy = SpyInner()
        let hub = hubTransport(inner: spy)
        try await hub.save([slice(.target, id: "1")])
        let secure: any CloudSyncTransport = try phoneTransport(inner: spy)

        let compacting = try XCTUnwrap(secure as? any CompactingTransport)
        let sweeping = try XCTUnwrap(secure as? any SweepingTransport)
        let hydrator = ReplicaHydrator(transport: secure, store: try ReplicaStore.inMemory(opener: TestE2E.opener()))
        _ = try await hydrator.hydrateOnce()
        let compacted = await spy.compacted
        XCTAssertEqual(compacted.map(\.0), [.data])
        XCTAssertEqual(compacted.map(\.1), [1])
        let removed = try await sweeping.sweepEvents(in: .relay, olderThan: stamp, upTo: CloudChangeToken(value: 4))
        XCTAssertEqual(removed, 3)
        let swept = await spy.swept
        XCTAssertEqual(swept.map(\.1), [4])
        try await compacting.compact(in: .relay, keepSince: CloudChangeToken(value: 2))
        let compactedAgain = await spy.compacted
        XCTAssertEqual(compactedAgain.count, 2)

        // An inner transport that buffers nothing: both are documented no-ops.
        let plain = try phoneTransport(inner: InMemoryCloudTransport())
        try await plain.compact(in: .data, keepSince: CloudChangeToken(value: 1))
        let none = try await plain.sweepEvents(in: .relay, olderThan: stamp, upTo: CloudChangeToken(value: 1))
        XCTAssertEqual(none, 0)
    }

    // MARK: - F2, F3, F4, F16

    func testTheHubPassesHellosThroughSealed() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        let hello = CloudRecord(
            recordName: "hello-\(TestE2E.deviceID.uuidString)", zone: .relay, kind: RelayRecordKind.hello.rawValue,
            modifiedAt: stamp, payload: Data("{\"device\":{}}".utf8))
        try await phone.save([hello])
        let wireBatch = try await inner.changes(in: .relay, since: nil)
        let wire = try XCTUnwrap(wireBatch.changed.first)

        let hub = hubTransport(inner: inner)
        let read = try await hub.changes(in: .relay, since: nil).changed

        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.recordName, hello.recordName)
        XCTAssertEqual(read.first?.kind, RelayRecordKind.hello.rawValue)
        XCTAssertEqual(read.first?.payload, wire.payload, "F4: the envelope stays sealed for handleHello")
        XCTAssertNil(read.first?.sealed, "nothing about the hello is authenticated yet")
    }

    func testTheHubOpensItsOwnEchoesAndTheRollbackGuardKeysOnTheSender() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner, keys: TestE2E.phone(firstSeq: 900))
        let hub = hubTransport(inner: inner, keys: TestE2E.hub(firstSeq: 5))
        try await phone.save([action()])
        let mine = try await phone.changes(in: .relay, since: nil)
        XCTAssertEqual(mine.changed.first?.sealed?.seq, 900)

        let received = try await hub.changes(in: .relay, since: nil)
        let opened = try XCTUnwrap(received.changed.first)
        try await hub.save([CloudRecord(
            recordName: opened.recordName, zone: .relay, kind: opened.kind, modifiedAt: stamp,
            payload: action(status: "applied").payload, sealed: opened.sealed)])

        let echo = try await phone.changes(in: .relay, since: mine.newToken).changed
        XCTAssertEqual(echo.count, 1, "seq 5 in the hub's space is not older than 900 in the phone's")
        XCTAssertEqual(echo.first?.sealed?.seq, 5)

        let own = try await hub.changes(in: .relay, since: received.newToken).changed
        XCTAssertEqual(own.map(\.recordName), ["action-a1"])
        XCTAssertEqual(own.first?.sealed?.senderID, TestE2E.hubID)
        XCTAssertEqual(own.first?.sealed?.envelopeClass, .relayToPhone)
        XCTAssertEqual(own.first?.payload, action(status: "applied").payload)
    }

    func testUnopenableRelayRecordsAreListedForHygiene() async throws {
        let inner = InMemoryCloudTransport()
        let stranger = try phoneTransport(inner: inner, keys: TestE2E.stranger())
        try await stranger.save([action("s1", deviceID: TestE2E.strangerDeviceID)])
        let phone = try phoneTransport(inner: inner)
        try await phone.save([action("p1")])
        let hub = hubTransport(inner: inner)

        let scan = try await hub.relayHygieneScan()

        XCTAssertEqual(scan.opened.map(\.recordName), ["action-p1"])
        XCTAssertEqual(scan.unopenable.count, 1)
        let strangerWire = try stranger.wireName(plain: "action-s1", zone: .relay)
        XCTAssertEqual(scan.unopenable.first, UnopenableRecord(wireName: strangerWire, modifiedAt: stamp, reason: "noRelayKey"))

        try await hub.deleteWire(wireNames: [strangerWire], in: .relay)
        let deleted = try await inner.changes(in: .relay, since: nil).deletedRecordNames
        XCTAssertEqual(deleted, [strangerWire])
    }

    func testTheEchoIsSealedToTheAuthenticatedSender() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)
        let sealedInfo = SealedInfo(
            wireName: "w", senderID: TestE2E.deviceID, epoch: 1, seq: 1, envelopeClass: .relayToHub)
        // The payload names another device; the echo still goes to the authenticated sender.
        let echo = CloudRecord(
            recordName: "action-a1", zone: .relay, kind: "action", modifiedAt: stamp,
            payload: action(deviceID: TestE2E.strangerDeviceID).payload, sealed: sealedInfo)
        try await hub.save([echo])

        let phone = try phoneTransport(inner: inner)
        let read = try await phone.changes(in: .relay, since: nil).changed
        XCTAssertEqual(read.map(\.recordName), ["action-a1"], "only the authenticated sender's key opens it")
    }

    func testAnEchoWithoutSealedInfoGoesToThePayloadsDevice() async throws {
        let inner = InMemoryCloudTransport()
        let hub = hubTransport(inner: inner)
        try await hub.save([action(status: "applied")])

        let read = try await phoneTransport(inner: inner).changes(in: .relay, since: nil).changed
        XCTAssertEqual(read.map(\.recordName), ["action-a1"])
    }

    func testARelayRecordWhosePayloadDeviceIDIsNotItsSenderIsStillReturnedWithTheAuthenticatedSender() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        try await phone.save([action(deviceID: TestE2E.strangerDeviceID)])

        let read = try await hubTransport(inner: inner).changes(in: .relay, since: nil).changed

        XCTAssertEqual(read.count, 1, "the processor decides on the mismatch; the transport does not hide it")
        XCTAssertEqual(read.first?.sealed?.senderID, TestE2E.deviceID)
    }

    func testThePhoneRefusesToWriteDataZone() async throws {
        let phone = try phoneTransport(inner: InMemoryCloudTransport())
        do {
            try await phone.save([slice()])
            XCTFail("expected wrongRole")
        } catch let error as SecureTransportError {
            XCTAssertEqual(error, .wrongRole)
        }
    }

    func testAnUnknownKindIsRefused() async throws {
        let hub = hubTransport(inner: InMemoryCloudTransport())
        let odd = CloudRecord(recordName: "odd-1", zone: .data, kind: "odd", modifiedAt: stamp, payload: Data())
        do {
            try await hub.save([odd])
            XCTFail("expected unknownKind")
        } catch let error as SecureTransportError {
            XCTAssertEqual(error, .unknownKind("odd"))
        }
    }

    // MARK: - Rollback guard

    func testInMemoryRollbackGuardKeysOnWireNameAndSender() throws {
        let guardStore = InMemoryRollbackGuard()
        let phone = UUID(), hub = UUID()
        XCTAssertEqual(try guardStore.check(wireName: "w", senderID: phone, epoch: 1, seq: 900), .newer)
        try guardStore.record(wireName: "w", senderID: phone, epoch: 1, seq: 900)
        XCTAssertEqual(try guardStore.check(wireName: "w", senderID: phone, epoch: 1, seq: 900), .same)
        XCTAssertEqual(try guardStore.check(wireName: "w", senderID: phone, epoch: 1, seq: 899), .older)
        XCTAssertEqual(try guardStore.check(wireName: "w", senderID: phone, epoch: 2, seq: 1), .newer)
        XCTAssertEqual(try guardStore.check(wireName: "w", senderID: hub, epoch: 1, seq: 5), .newer, "F3")
    }

    // MARK: - Fix round 1

    func testARolledBackRecordIsListedForHygiene() async throws {
        let inner = InMemoryCloudTransport()
        let phone = try phoneTransport(inner: inner)
        let hub = hubTransport(inner: inner)
        let version1 = try await phone.seal(action(status: "pending"))
        let version2 = try await phone.seal(action(status: "cancelled"))
        try await inner.save([version2])
        _ = try await hub.changes(in: .relay, since: nil)
        try await inner.save([version1])

        let scan = try await hub.relayHygieneScan()

        XCTAssertTrue(scan.opened.isEmpty)
        XCTAssertEqual(scan.unopenable, [UnopenableRecord(wireName: version1.recordName, modifiedAt: stamp, reason: "rolledBack")],
                       "F2: hygiene can still age out a rolled-back copy by wire name")
    }

    func testASignalShapedRecordInRelayZoneIsNotPassedThrough() async throws {
        let inner = InMemoryCloudTransport()
        let rejections = Rejections()
        let hub = hubTransport(inner: inner, rejections: rejections)
        let forged = CloudRecord(
            recordName: "action-a1", zone: .relay, kind: WireKind.signal, modifiedAt: stamp,
            payload: action().payload)
        let shaped = CloudRecord(
            recordName: "sig-abcdefghijklmnopqrstuvwxyz", zone: .relay, kind: WireKind.signal, modifiedAt: stamp,
            payload: Data())
        try await inner.save([forged, shaped])

        let read = try await hub.changes(in: .relay, since: nil).changed
        let scan = try await hub.relayHygieneScan()

        XCTAssertTrue(read.isEmpty, "signals live in DataZone only (D14); a relay \"sig\" record is unauthenticated")
        XCTAssertEqual(rejections.values.map(\.reason), ["signalInRelayZone", "signalInRelayZone"])
        XCTAssertEqual(scan.unopenable.map(\.wireName), ["action-a1", shaped.recordName])
    }

    func testALockedKeyInsideTheOwnEchoLoopPropagates() async throws {
        let inner = InMemoryCloudTransport()
        let hubKeys = TestE2E.hub()
        let rejections = Rejections()
        let hub = hubTransport(inner: inner, keys: hubKeys, rejections: rejections)
        try await hub.save([action(status: "applied")])
        hubKeys.isLocked = true

        do {
            _ = try await hub.changes(in: .relay, since: nil)
            XCTFail("expected keysUnavailable")
        } catch let error as SecureTransportError {
            XCTAssertEqual(error, .keysUnavailable, "a locked key is never a miss in the h2p key loop")
        }
        XCTAssertTrue(rejections.values.isEmpty, "nothing dropped while locked")

        hubKeys.isLocked = false
        let replay = try await hub.changes(in: .relay, since: nil)
        XCTAssertEqual(replay.changed.map(\.recordName), ["action-a1"], "the kept token replays after unlock")
    }

    func testAForgedHubEchoIsUnopenableAtTheHub() async throws {
        let inner = InMemoryCloudTransport()
        let wire = "abcdefghijklmnopqrstuvwxyz"
        // Claims to be the hub's own h2p echo, sealed under a key no linked device holds.
        let forged = try EnvelopeSealer.sealSymmetric(
            InnerFrame(kind: "action", id: "action-a1", payload: action(status: "applied").payload),
            envelopeClass: .relayToPhone, key: SymmetricKey(size: .bits256), hubID: TestE2E.hubID,
            senderID: TestE2E.hubID, epoch: 1, seq: 99, context: EnvelopeContext(zone: .relay, wireName: wire),
            signer: nil)
        try await inner.save([CloudRecord(recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: stamp, payload: forged)])
        let rejections = Rejections()
        let hub = hubTransport(inner: inner, rejections: rejections)

        let read = try await hub.changes(in: .relay, since: nil).changed
        let scan = try await hub.relayHygieneScan()

        XCTAssertTrue(read.isEmpty)
        XCTAssertEqual(rejections.values.map(\.reason), ["noRelayKey"])
        XCTAssertEqual(scan.unopenable, [UnopenableRecord(wireName: wire, modifiedAt: stamp, reason: "noRelayKey")])
    }

    // MARK: - Fix round 2

    func testADataZoneSignalWithoutTheSigPrefixNeverReachesTheConsumer() async throws {
        let inner = InMemoryCloudTransport()
        let rejections = Rejections()
        let phone = try phoneTransport(inner: inner, rejections: rejections)
        let wellShaped = CloudRecord(
            recordName: "sig-abcdefghijklmnopqrstuvwxyz", zone: .data, kind: WireKind.signal, modifiedAt: stamp, payload: Data())
        let misnamed = CloudRecord(
            recordName: "target-7", zone: .data, kind: WireKind.signal, modifiedAt: stamp, payload: Data())
        try await inner.save([wellShaped, misnamed])

        let read = try await phone.changes(in: .data, since: nil).changed

        XCTAssertEqual(read, [wellShaped], "only the signal shape passes")
        XCTAssertEqual(rejections.values.map(\.wireName), ["target-7"])
        XCTAssertEqual(rejections.values.map(\.reason), ["malformedSignal"])
    }

    func testADataZoneSignalWithAPayloadNeverReachesTheConsumer() async throws {
        let inner = InMemoryCloudTransport()
        let rejections = Rejections()
        let phone = try phoneTransport(inner: inner, rejections: rejections)
        let wellShaped = CloudRecord(
            recordName: "sig-abcdefghijklmnopqrstuvwxyz", zone: .data, kind: WireKind.signal, modifiedAt: stamp, payload: Data())
        let carrying = CloudRecord(
            recordName: "sig-bcdefghijklmnopqrstuvwxyz2", zone: .data, kind: WireKind.signal, modifiedAt: stamp,
            payload: Data("{\"title\":\"plaintext\"}".utf8))
        try await inner.save([wellShaped, carrying])

        let read = try await phone.changes(in: .data, since: nil).changed

        XCTAssertEqual(read, [wellShaped])
        XCTAssertEqual(rejections.values.map(\.wireName), [carrying.recordName])
        XCTAssertEqual(rejections.values.map(\.reason), ["malformedSignal"])
    }
}
