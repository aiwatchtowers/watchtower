import CryptoKit
import Foundation
import os
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerE2ETesting
import WatchtowerSync

/// The relay side of the hub (mobile POC spec §5.2): exactly-once handling,
/// age, the probe, the kinds the POC refuses, backlog batching and hygiene.
/// Every phone record is sealed by a `TestE2E` phone and read through the
/// hub's `SecureTransport` (mobile E2E spec §2.2): the key-based device gate,
/// sealed echoes and relay hygiene by wire name live here too.
@MainActor
final class RelayProcessorTests: XCTestCase {
    private var transport: StubHubTransport!
    private var sidecar: HubSyncState!
    private var dispatcher: MobileHubCommandDispatcher!
    /// The hub's keys: the paired test phone is linked.
    private var hubKeys: TestHubKeyProvider!

    override func setUp() async throws {
        transport = StubHubTransport()
        sidecar = try HubSyncState.inMemory()
        hubKeys = TestE2E.hub()
        // Every test action comes from this linked phone (the device gate
        // has its own tests in MobileLinkCenterTests).
        try sidecar.linkTestDevice()
        dispatcher = MobileHubCommandDispatcher()
    }

    override func tearDown() async throws {
        transport = nil
        sidecar = nil
        dispatcher = nil
        hubKeys = nil
    }

    private func makeProcessor(
        batchLimit: Int = RelayProcessor.defaultBatchLimit,
        onRejected: (@Sendable (String, String) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> RelayProcessor {
        RelayProcessor(
            transport: testSecureTransport(transport, keys: hubKeys, onRejected: onRejected), sidecar: sidecar,
            dispatcher: dispatcher, hubID: "hub-acme", batchLimit: batchLimit, now: now
        )
    }

    /// The hub's side of the zone, sealing as the processor does (a hub echo written by a test).
    private var hubSide: SecureTransport { testSecureTransport(transport, keys: hubKeys) }

    /// Every echo the hub wrote for the wire record `recordName`, in order, opened by the paired phone.
    private func echoes(of recordName: String) throws -> [ActionRequestPayload] {
        try transport.openedEchoes()
            .filter { $0.sealed?.wireName == recordName }
            .map { try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: $0.payload) }
            .filter { $0.status != .pending }
    }

    // MARK: - Device records

    /// A phone's `device` record is phone activity: the hub keeps the
    /// active cadence for the grant traffic that follows.
    func testAHandedOverDeviceRecordCountsAsPhoneActivity() async throws {
        let payload = DevicePayload(
            deviceID: testPhoneID, name: "iPhone", model: "iPhone18,1", appVersion: "0.0.0-test", scope: .private,
            userRecordName: "_owner-acme", linkNonce: "nonce-acme", typingRequested: false, startSessions: true,
            updatedAt: Date()
        )
        try await transport.save([try TestRelayPhone.seal(try CloudRecordFactory.record(for: payload, modifiedAt: Date()))])
        let processor = RelayProcessor(
            transport: testSecureTransport(transport, keys: hubKeys), sidecar: sidecar, dispatcher: dispatcher,
            hubID: "hub-acme", deviceRecords: .init { _ in }
        )
        XCTAssertNil(processor.lastActivityAt)

        _ = try await processor.processOnce()

        XCTAssertNotNil(processor.lastActivityAt)
    }

    // MARK: - Key-authenticated phones (mobile E2E spec §2.2, D4, D9, D10)

    /// A plain probe from `deviceID`, `createdAt` = `created`.
    private func plainProbe(
        _ nonce: String, deviceID: String? = testPhoneID, created: Date = Date(), modifiedAt: Date? = nil
    ) throws -> CloudRecord {
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .probe, entityID: nil, params: ["nonce": .string(nonce)], createdAt: created,
            deviceID: deviceID
        )
        return try CloudRecordFactory.record(for: action, modifiedAt: modifiedAt ?? created)
    }

    /// The key-auth twin of the creator-gate tests (MobileLinkCenterTests): what opens under the linked phone's
    /// pairwise key and names that phone is applied.
    func testAnActionThatOpensWithALinkedPhonesKeyIsApplied() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied(["comment_id": .integer(1)])
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        XCTAssertEqual(record.kind, WireKind.envelope, "the phone's save is sealed")
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try echoes(of: record.recordName).map(\.status), [.applied])
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
    }

    /// The payload's id must name the record the envelope authenticated (target 148): a frame `action-X` whose
    /// payload is `action-Y` is dropped, so it can neither claim, ledger nor echo Y.
    func testAnActionWhosePayloadNamesAnotherRecordIsIgnored() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied(["comment_id": .integer(1)])
        }
        let action = ActionRequestPayload(
            id: "Y", kind: .boardCommentAdd, entityID: "7", params: [:], createdAt: Date(), deviceID: testPhoneID)
        let plain = try CloudRecordFactory.record(for: action, modifiedAt: Date())
        let record = try TestRelayPhone.seal(CloudRecord(
            recordName: "action-X", zone: plain.zone, kind: plain.kind, modifiedAt: plain.modifiedAt,
            payload: plain.payload))
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try echoes(of: record.recordName).isEmpty)
        XCTAssertTrue(try echoes(of: try TestRelayPhone.wireName("action-Y")).isEmpty)
        XCTAssertNil(try sidecar.relayPhase("action-X"))
        XCTAssertNil(try sidecar.relayPhase("action-Y"))
    }

    /// D9: a record sealed under a key the hub does not hold is dropped by the transport and reported; the
    /// processor never sees it, so nothing is echoed (the hub could not seal an answer) or ledgered. The
    /// sidecar even lists the stranger's id: the key decides, not the payload.
    func testAnActionSealedByAnUnlinkedKeyNeverReachesTheProcessor() async throws {
        try sidecar.linkTestDevice(TestE2E.strangerDeviceID.uuidString)
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(
            kind: .boardCommentAdd, entityID: "7", deviceID: TestE2E.strangerDeviceID.uuidString,
            sender: TestE2E.strangerIdentity)
        try await transport.save([record])
        let rejected = OSAllocatedUnfairLock<[String]>(initialState: [])

        let report: @Sendable (String, String) -> Void = { wire, _ in rejected.withLock { $0.append(wire) } }
        let processor = makeProcessor(onRejected: report)
        let pass = try await processor.processOnce()

        XCTAssertEqual(pass.handled, 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(rejected.withLock { $0 }, [record.recordName], "dropped and reported once")
        XCTAssertNil(try sidecar.relayPhase(record.plainName), "never ledgered")
        XCTAssertEqual(transport.saved.count, 1, "never echoed: the stub holds only the stranger's save")
    }

    /// The sender check: the payload names another linked phone than the one whose key opened the record. It
    /// fails `device_not_linked`, and the echo is sealed to the sender, not to the phone the payload names (F16).
    func testAPayloadNamingAnotherDeviceThanItsSenderFailsDeviceNotLinked() async throws {
        let other = TestE2E.strangerDeviceID.uuidString
        try sidecar.linkTestDevice(other)
        hubKeys.link(TestE2E.strangerIdentity)
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7", deviceID: other)
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0)
        let echo = try XCTUnwrap(try echoes(of: record.recordName).first, "the sender reads the answer")
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .deviceNotLinked)
        XCTAssertTrue(transport.openedEchoes(as: TestE2E.strangerIdentity).isEmpty, "the named phone cannot open it")
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:device_not_linked")
        XCTAssertNil(try sidecar.deviceLastSeq(other))
    }

    /// D10: after a rotation the hub accepts the previous epoch's relay envelopes for 7 days; past the grace the
    /// same envelope no longer opens and is dropped unanswered.
    func testAnActionOfThePreviousEpochIsAppliedDuringTheGrace() async throws {
        hubKeys.currentEpochValue = 2
        let inGrace = try TestRelayPhone.seal(try plainProbe("in-grace"), epoch: 1)
        try await transport.save([inGrace])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try echoes(of: inGrace.recordName).map(\.status), [.applied])

        hubKeys.acceptsPreviousEpoch = false
        let late = try TestRelayPhone.seal(try plainProbe("late"), epoch: 1)
        try await transport.save([late])
        _ = try await makeProcessor().processOnce()

        XCTAssertTrue(try echoes(of: late.recordName).isEmpty, "past the grace: dropped, never answered")
        XCTAssertNil(try sidecar.relayPhase(late.plainName))
    }

    /// The echo leaves the hub as an envelope under the record's opaque name; only the phone whose key opened
    /// the request can read it.
    func testTheEchoIsSealedForThePhoneAndOpensOnlyWithItsKey() async throws {
        hubKeys.link(TestE2E.strangerIdentity)
        let record = try pendingActionRecord(kind: .probe, params: ["nonce": .string("secret-nonce")])
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        let wire = try XCTUnwrap(transport.saved.map(\.record).last { $0.recordName == record.recordName && $0 != record })
        XCTAssertEqual(wire.kind, WireKind.envelope)
        XCTAssertNotEqual(wire.recordName, record.plainName, "the plain name never reaches the wire")
        XCTAssertNil(wire.payload.range(of: Data("secret-nonce".utf8)), "no plaintext on the wire")
        let opened = try TestRelayPhone.open(wire)
        XCTAssertEqual(opened.sealed?.senderID, TestE2E.hubID)
        XCTAssertEqual(opened.sealed?.envelopeClass, .relayToPhone)
        XCTAssertEqual(try decodeAction(opened).status, .applied)
        XCTAssertThrowsError(try TestRelayPhone.open(wire, as: TestE2E.strangerIdentity), "another phone's key fails")
    }

    /// F2: hygiene sees the hub's own echoes (it opens them) and the records nobody here can open; both are
    /// deleted by wire name once older than `actionMaxAge`. A fresh unopenable record stays.
    func testHygieneAgesOutTheHubsOwnEchoesAndUnopenableRecordsByWireName() async throws {
        let now = Date()
        let old = now.addingTimeInterval(-(RelayProcessor.actionMaxAge + 3600))
        var applied = ActionRequestPayload(id: "aged-echo", kind: .probe, entityID: nil, createdAt: old, deviceID: testPhoneID)
        applied.status = .applied
        try await hubSide.save([try CloudRecordFactory.record(for: applied, modifiedAt: old)])
        let echoWire = try TestRelayPhone.wireName(applied.recordName)
        let agedStranger = try TestRelayPhone.seal(
            try plainProbe("aged", deviceID: TestE2E.strangerDeviceID.uuidString, created: old), as: TestE2E.strangerIdentity)
        let freshStranger = try TestRelayPhone.seal(
            try plainProbe("fresh", deviceID: TestE2E.strangerDeviceID.uuidString, created: now),
            as: TestE2E.strangerIdentity)
        let freshPending = try pendingActionRecord(kind: .probe, params: ["nonce": .string("fresh")], age: 60, now: now)
        try await transport.save([agedStranger, freshStranger, freshPending])

        try await makeProcessor { now }.runHygieneIfDue()

        let names = Set(try await transport.changes(in: .relay, since: nil).changed.map(\.recordName))
        XCTAssertFalse(names.contains(echoWire), "the hub's own aged echo is deleted")
        XCTAssertFalse(names.contains(agedStranger.recordName), "an aged unopenable record is deleted by wire name")
        XCTAssertTrue(names.contains(freshStranger.recordName), "a fresh unopenable record stays")
        XCTAssertTrue(names.contains(freshPending.recordName), "a fresh pending record from the linked phone stays")
    }

    /// Uploads have no age window (Task 12 ruling): an upload's ledger row and the rollback-guard rows of an
    /// accepted epoch outlive the 8-day cutoff until that epoch leaves the D10 grace; actions keep the cutoff.
    func testPruningKeepsUploadRowsWhileTheirEpochIsAccepted() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        try sidecar.writeKeys { db in
            try HubSyncState.insertEpoch(
                HubSyncState.StoredEpoch(epoch: 1, sealedKeys: Data(count: 32), createdAt: start, firstSeq: 0, retiredAt: nil), db)
        }
        let phone = TestE2E.deviceID.uuidString
        try sidecar.markRelayDone("recupload-R1", outcome: "received", at: start.addingTimeInterval(day))
        try sidecar.markRelayDone("action-A1", outcome: "applied", at: start.addingTimeInterval(day))
        try sidecar.recordRelaySeen(wireName: "wire-1", senderID: phone, epoch: 1, seq: 5, at: start.addingTimeInterval(day))
        let later = start.addingTimeInterval(20 * day)

        try sidecar.pruneRelayProcessed(olderThan: later.addingTimeInterval(-8 * day), now: later)

        XCTAssertEqual(try sidecar.relayPhase("recupload-R1"), .done, "epoch 1 is current: kept")
        XCTAssertNil(try sidecar.relayPhase("action-A1"), "actions keep the cutoff (their age gate)")
        XCTAssertNotNil(try sidecar.relaySeen(wireName: "wire-1", senderID: phone))

        // Epoch 2 begins; epoch 1 stays accepted for the 7-day grace, then goes.
        try sidecar.writeKeys { db in
            try db.execute(sql: "UPDATE hub_epochs SET retired_at = ? WHERE epoch = 1", arguments: [later.timeIntervalSince1970])
            try HubSyncState.insertEpoch(
                HubSyncState.StoredEpoch(epoch: 2, sealedKeys: Data(count: 32), createdAt: later, firstSeq: 0, retiredAt: nil), db)
        }
        let inGrace = later.addingTimeInterval(6 * day)
        try sidecar.pruneRelayProcessed(olderThan: inGrace.addingTimeInterval(-8 * day), now: inGrace)
        XCTAssertEqual(try sidecar.relayPhase("recupload-R1"), .done, "in the grace: kept")
        XCTAssertNotNil(try sidecar.relaySeen(wireName: "wire-1", senderID: phone))

        let pastGrace = later.addingTimeInterval(8 * day)
        try sidecar.pruneRelayProcessed(olderThan: pastGrace.addingTimeInterval(-8 * day), now: pastGrace)
        XCTAssertNil(try sidecar.relayPhase("recupload-R1"), "its epoch no longer opens: pruned")
        XCTAssertNil(try sidecar.relaySeen(wireName: "wire-1", senderID: phone))
    }

    // MARK: - The real keyring (HubKeyring over the sidecar's devices table)

    /// D9 end to end: the hub's real `HubKeyring` derives relay keys from the same `devices` rows the gate reads.
    /// After Remove, the phone's relay records of the current and the previous epoch get no echo, no ledger
    /// row and no ingest.
    func testARemovedPhonesRecordsGetNoEchoAndNoIngestWithTheRealKeyring() async throws {
        let hubID = try sidecar.ensureHubID()
        let ring = try HubKeyring(hubID: hubID, sidecar: sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let identity = DeviceIdentityKeys(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
        let phoneID = identity.deviceID.uuidString
        let nonce = Data(repeating: 0x5A, count: 32)
        try sidecar.linkTestDevice(phoneID)
        _ = try sidecar.writeKeys { db in
            try db.execute(
                sql: "UPDATE devices SET signing_key = ?, agreement_key = ?, link_nonce = ? WHERE device_id = ?",
                arguments: [
                    identity.signing.publicKey.rawRepresentation, identity.agreement.publicKey.rawRepresentation,
                    WireBytes.base64URL(nonce), phoneID
                ])
        }
        let store = try InMemoryPhoneKeyStore(identity: identity)
        try store.saveHubLink(HubLinkKeys(
            hubID: hubID, hubSigningKey: ring.signingPublicKey.rawRepresentation,
            hubAgreementKey: ring.agreementPublicKey.rawRepresentation, linkNonce: nonce,
            metaKey: ring.metaKey().withUnsafeBytes { Data($0) },
            epochs: [EpochKeys(
                epoch: 1, dataKey: ring.dataKey(epoch: 1).withUnsafeBytes { Data($0) },
                alertKey: ring.alertKey(epoch: 1).withUnsafeBytes { Data($0) })]))
        let phone = SecureTransport(
            inner: transport,
            keys: try PhoneKeyProvider(store: store, hubID: hubID, seq: SeqAllocator(load: { 1 }, store: { _ in })),
            rollback: InMemoryRollbackGuard())
        let ingests = OSAllocatedUnfairLock(initialState: 0)
        let countIngest: RelayProcessor.RecordingIngest = { _, _ in ingests.withLock { $0 += 1 } }
        let processor = RelayProcessor(
            transport: MobileHubStorage.sealing(transport, keyring: ring, sidecar: sidecar), sidecar: sidecar,
            dispatcher: dispatcher, hubID: hubID, recordingUploads: .init(ingest: countIngest))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        /// A probe and an upload from the phone; returns their plain names.
        func send(_ label: String) async throws -> [String] {
            let probe = ActionRequestPayload(
                id: "probe-\(label)", kind: .probe, entityID: nil, params: ["nonce": .string(label)], createdAt: Date(),
                deviceID: phoneID)
            let audio = dir.appendingPathComponent("\(label).plain")
            try Data(repeating: 0xCD, count: 64).write(to: audio)
            let sealedAudio = dir.appendingPathComponent("\(label).sealed")
            let descriptor = try ChunkedAssetCipher.encryptFile(at: audio, to: sealedAudio)
            let upload = RecordingUploadPayload(
                id: "up-\(label)", startedAt: Date(), endedAt: Date(), durationSec: 1, titleHint: nil,
                sampleFormat: "aac-64k-mono", eventID: nil, deviceID: phoneID, hubID: nil)
            let plainUpload = try CloudRecordFactory.record(for: upload, modifiedAt: Date(), assetFileURL: sealedAudio)
            try await phone.save([
                try CloudRecordFactory.record(for: probe, modifiedAt: Date()),
                CloudRecord(
                    recordName: plainUpload.recordName, zone: .relay, kind: plainUpload.kind, modifiedAt: plainUpload.modifiedAt,
                    payload: plainUpload.payload, assetFileURL: sealedAudio, asset: descriptor)
            ])
            return [probe.recordName, upload.recordName]
        }

        // Control: while linked, both are answered and the upload is ingested.
        let linked = try await send("linked")
        _ = try await processor.processOnce()
        XCTAssertEqual(try linked.map { try sidecar.relayPhase($0) }, [.done, .done])
        XCTAssertEqual(ingests.withLock { $0 }, 1)

        // Remove: the phone leaves `devices`; the keyring has no relay key for it any more.
        XCTAssertNotNil(try sidecar.removeLinkedDevice(phoneID))
        let current = try await send("current-epoch")
        let savesBefore = transport.saved.count
        _ = try await processor.processOnce()
        XCTAssertEqual(transport.saved.count, savesBefore, "no echo for the removed phone")

        // A rotation: its records of the previous epoch (inside the D10 grace) are refused the same way.
        try ring.rotate(reason: .manual)
        let previous = try await send("previous-epoch")
        let savesBeforePrevious = transport.saved.count
        _ = try await processor.processOnce()
        XCTAssertEqual(transport.saved.count, savesBeforePrevious, "no echo for the previous epoch either")

        for name in current + previous {
            XCTAssertNil(try sidecar.relayPhase(name), "\(name) is never ledgered")
        }
        XCTAssertEqual(ingests.withLock { $0 }, 1, "nothing ingested after Remove")
    }

    /// The age rule reads the sealed `created_at`: a phone save with a fresh plaintext `modifiedAt` cannot make
    /// an old request look new.
    func testAnExpiredCreatedAtStillExpiresNowThatItIsAuthenticated() async throws {
        let now = Date()
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let action = ActionRequestPayload(
            id: UUID().uuidString, kind: .boardCommentAdd, entityID: "7",
            createdAt: now.addingTimeInterval(-(RelayProcessor.actionMaxAge + 60)), deviceID: testPhoneID)
        let record = try TestRelayPhone.seal(try CloudRecordFactory.record(for: action, modifiedAt: now))
        try await transport.save([record])

        _ = try await makeProcessor { now }.processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try echoes(of: record.recordName).map(\.status), [.expired])
    }

    /// D4: CloudKit does not order deliveries, so a lower seq after a higher one from the same phone (another
    /// record) is applied; `last_seq` only keeps the highest seen.
    func testLastSeqIsAHighWaterMarkNotAGate() async throws {
        let later = try TestRelayPhone.seal(try plainProbe("twelve"), seq: 12)
        let earlier = try TestRelayPhone.seal(try plainProbe("nine"), seq: 9)
        try await transport.save([later])
        _ = try await makeProcessor().processOnce()
        try await transport.save([earlier])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try echoes(of: later.recordName).map(\.status), [.applied])
        XCTAssertEqual(try echoes(of: earlier.recordName).map(\.status), [.applied], "seq 9 after 12 is applied")
        XCTAssertEqual(try sidecar.deviceLastSeq(testPhoneID), 12)
    }

    // MARK: - Probe

    func testProbeDeliveredTwiceEchoesTheSameAppliedNonceAndHubID() async throws {
        let record = try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-1")])
        try await transport.save([record])
        let processor = makeProcessor()

        _ = try await processor.processOnce()
        // The same pending record arrives again (the phone's save won over the echo).
        try await transport.save([record])
        _ = try await processor.processOnce()

        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.count, 2, "a done probe read pending again is re-echoed")
        XCTAssertEqual(echoes.map(\.status), [.applied, .applied])
        XCTAssertEqual(echoes.map(\.result), Array(repeating: ["nonce": .string("n-1"), "hub_id": .string("hub-acme")], count: 2))
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
    }

    func testProbeWithoutNonceFailsInvalidParams() async throws {
        let record = try pendingActionRecord(kind: .probe)
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .invalidParams)
    }

    // MARK: - Exactly-once (§5.2 rule 1)

    func testNonIdempotentKindIsMarkedBegunBeforeItsHandlerRuns() async throws {
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        var phaseInHandler: HubSyncState.RelayPhase?
        var calls = 0
        dispatcher.register(.boardCommentAdd) { [sidecar] _ in
            calls += 1
            phaseInHandler = try sidecar?.relayPhase(record.plainName)
            return .applied(["comment_id": .integer(42)])
        }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1, "a non-idempotent kind is applied once")
        XCTAssertEqual(phaseInHandler, .begun, "`begun` is committed before the write")
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.status, .applied)
        XCTAssertEqual(echo.result, ["comment_id": .integer(42)])
    }

    func testIdempotentKindIsNotMarkedBegun() async throws {
        let record = try pendingActionRecord(kind: .boardTargetStatus, entityID: "7")
        var phaseInHandler: HubSyncState.RelayPhase?
        dispatcher.register(.boardTargetStatus) { [sidecar] _ in
            phaseInHandler = try sidecar?.relayPhase(record.plainName)
            return .applied(["status": .string("done")])
        }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertNil(phaseInHandler, "an idempotent kind simply re-runs, it is never `begun`")
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
    }

    func testRecordFoundBegunAtStartFailsOutcomeUnknownAndIsNeverApplied() async throws {
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        try await transport.save([record])
        // The previous run crashed between `begun` and `done`.
        try sidecar.markRelayBegun(record.plainName, at: Date())

        _ = try await makeProcessor().processOnce()
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0, "an interrupted apply is never re-run")
        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.count, 2, "the second read re-echoes the stored outcome")
        XCTAssertEqual(echoes.map(\.status), [.failed, .failed])
        XCTAssertEqual(echoes.map(\.reason), [.outcomeUnknown, .outcomeUnknown])
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
    }

    func testADoneActionReadPendingAgainIsReEchoedFromTheStoredOutcomeWithoutDispatching() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied(["comment_id": .integer(42)])
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        // A lost ack: the phone re-saved its pending copy and that save won.
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1, "a re-echo never dispatches again")
        let written = try echoes(of: record.recordName)
        XCTAssertEqual(written.map(\.status), [.applied, .applied])
        XCTAssertEqual(written.last?.result, ["comment_id": .integer(42)], "the same comment, not a second one")
        let stored = try await transport.changes(in: .relay, since: nil).changed.first { $0.recordName == record.recordName }
        XCTAssertEqual(try decodeAction(try XCTUnwrap(stored)).status, .applied, "the record reads applied again")

        // Its own echo read back is no work.
        _ = try await makeProcessor().processOnce()
        XCTAssertEqual(try echoes(of: record.recordName).count, 2)
    }

    /// CloudKit never buffers the hub's own echo: a re-read (a pass that
    /// left a backlog, a reset rewinding the cursor) still shows the phone's
    /// `pending` save of every action already done. Those stale copies are
    /// no work, so the backlog drains; a later phone save is re-echoed
    /// outside the batch budget.
    func testOwnStaleBufferedCopiesAreNotReEchoedAndNeverStallTheBacklog() async throws {
        let buffer = PhoneOnlyBuffer()
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied(["comment_id": .integer(42)])
        }
        let records = try (0..<2).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await buffer.phone.save(records)
        let processor = RelayProcessor(
            transport: testSecureTransport(buffer, keys: hubKeys), sidecar: sidecar, dispatcher: dispatcher,
            hubID: "hub-acme", batchLimit: 1
        )

        var passes = [try await processor.processOnce()]
        while let last = passes.last, last.remaining > 0, passes.count < 5 {
            passes.append(try await processor.processOnce())
        }

        XCTAssertEqual(passes.map(\.remaining), [1, 0], "the second pass finishes the backlog")
        XCTAssertEqual(calls, 2)
        let echoed = await buffer.echoes.map(\.recordName)
        XCTAssertEqual(echoed.sorted(), records.map(\.recordName).sorted(), "one echo each")
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "the token advances")

        try sidecar.wipeSyncState(now: Date())  // an account reset rewinds the relay cursor
        _ = try await processor.processOnce()
        let afterReset = await buffer.echoes.count
        XCTAssertEqual(afterReset, 2, "a re-read from the start re-echoes nothing")

        // A lost ack: the phone saves its pending copy again.
        try await buffer.phone.save([records[0]])
        let pass = try await processor.processOnce()
        XCTAssertEqual(pass.remaining, 0, "a re-echo never takes the batch budget")
        let after = await buffer.echoes.map(\.recordName)
        XCTAssertEqual(after.filter { $0 == records[0].recordName }.count, 2, "the later phone save is re-echoed")
        XCTAssertEqual(calls, 2)
    }

    func testADoneActionStuckAtReceivedIsReEchoedWithItsFinalOutcome() async throws {
        var calls = 0
        dispatcher.register(.sessionStart) { _ in
            calls += 1
            return .applied(["stage": .string("starting")])
        }
        let record = try pendingActionRecord(kind: .sessionStart, entityID: "7")
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        // Only the hub's `received` echo reached the server; the final one was lost.
        var received = try decodeAction(record)
        received.status = .received
        try await hubSide.save([try CloudRecordFactory.record(for: received, modifiedAt: Date())])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1)
        let last = try XCTUnwrap(try echoes(of: record.recordName).last)
        XCTAssertEqual(last.status, .applied)
        XCTAssertEqual(last.result, ["stage": .string("starting")])
    }

    func testADoneLedgerRowWithoutAStoredEchoIsSkipped() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        // A row written before the ledger kept echoes.
        try sidecar.markRelayDone(record.plainName, outcome: "applied", at: Date())
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try echoes(of: record.recordName).isEmpty, "nothing stored, nothing to re-echo")
    }

    func testASidecarWithoutTheEchoColumnGainsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayLedger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hubstate.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE relay_processed (
                    record_name TEXT PRIMARY KEY,
                    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
                    outcome TEXT,
                    updated_at REAL NOT NULL DEFAULT 0
                );
                INSERT INTO relay_processed (record_name, phase, outcome, updated_at) VALUES ('action-old', 'done', 'applied', 1);
                """)
        }

        let reopened = try HubSyncState(path: path)

        XCTAssertEqual(try reopened.relayPhase("action-old"), .done)
        XCTAssertNil(try reopened.relayEcho("action-old"))
        try reopened.markRelayDone("action-new", outcome: "applied", echo: Data("{}".utf8), at: Date())
        XCTAssertEqual(try reopened.relayEcho("action-new"), Data("{}".utf8))
        // A second open over the migrated file is a no-op.
        XCTAssertEqual(try HubSyncState(path: path).relayEcho("action-new"), Data("{}".utf8))
    }

    /// A sidecar from before B18 (no `typing_requested`, no held lines)
    /// gains both in place: a linked phone keeps its grants, unrequested.
    func testASidecarWithoutTheTypingRequestColumnGainsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayLedger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hubstate.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE devices (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    user_record_name TEXT NOT NULL,
                    linked_at REAL NOT NULL,
                    typing_allowed INTEGER NOT NULL DEFAULT 0,
                    start_sessions_allowed INTEGER NOT NULL DEFAULT 1,
                    decided_at REAL
                );
                INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, typing_allowed)
                VALUES ('phone-a', 'iPhone', 'private', '_owner-acme', 1, 1);
                """)
        }

        let reopened = try HubSyncState(path: path)

        let device = try XCTUnwrap(try reopened.linkedDevice("phone-a"))
        XCTAssertTrue(device.typingAllowed)
        XCTAssertFalse(device.typingRequested)
        XCTAssertTrue(try reopened.setTypingRequested(true, deviceID: "phone-a"))
        XCTAssertTrue(try XCTUnwrap(try reopened.linkedDevice("phone-a")).typingRequested)
        XCTAssertTrue(try reopened.heldLines().isEmpty)
        // A second open over the migrated file is a no-op.
        XCTAssertTrue(try XCTUnwrap(try HubSyncState(path: path).linkedDevice("phone-a")).typingRequested)
    }

    /// Two instances opening an old file at once (a relaunch overlap) both
    /// open: the upgrade runs in an IMMEDIATE transaction.
    func testConcurrentOpensOfAnOldSidecarAllSucceed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayLedger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hubstate.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE relay_processed (
                    record_name TEXT PRIMARY KEY,
                    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
                    outcome TEXT,
                    updated_at REAL NOT NULL DEFAULT 0
                );
                INSERT INTO relay_processed (record_name, phase, outcome, updated_at) VALUES ('action-old', 'done', 'applied', 1);
                """)
        }
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                _ = try HubSyncState(path: path)
            } catch {
                failures.withLock { $0.append(error.localizedDescription) }
            }
        }

        XCTAssertEqual(failures.withLock { $0 }, [])
        let reopened = try HubSyncState(path: path)
        XCTAssertNil(try reopened.relayDoneSeq("action-old"), "an old row holds no buffer mark")
        try reopened.markRelayDone("action-new", outcome: "applied", doneSeq: 7, at: Date())
        XCTAssertEqual(try reopened.relayDoneSeq("action-new"), 7)
    }

    func testReceivedIsEchoedBeforeTheHandlerForStartLikeKinds() async throws {
        let record = try pendingActionRecord(kind: .sessionStart, entityID: "7")
        var echoesInHandler: [ActionStatus] = []
        dispatcher.register(.sessionStart) { [weak self] _ in
            echoesInHandler = try self?.echoes(of: record.recordName).map(\.status) ?? []
            return .applied(["stage": .string("starting")])
        }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(echoesInHandler, [.received], "the phone sees `received` before any work")
        XCTAssertEqual(try echoes(of: record.recordName).map(\.status), [.received, .applied])
    }

    func testThrowingHandlerFailsWriteFailed() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "disk on fire" } }
        let record = try pendingActionRecord(kind: .boardTargetPriority, entityID: "7")
        dispatcher.register(.boardTargetPriority) { _ in throw Boom() }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .writeFailed)
        XCTAssertEqual(echo.errorMessage, "disk on fire")
    }

    // MARK: - Age (§5.2 rule 5)

    func testActionOlderThanSevenDaysExpiresAndSixDaysOldIsApplied() async throws {
        let now = Date()
        let stale = try pendingActionRecord(
            kind: .probe, params: ["nonce": .string("old")], age: 7 * 86_400 + 1, now: now
        )
        let fresh = try pendingActionRecord(
            kind: .probe, params: ["nonce": .string("new")], age: 6 * 86_400, now: now
        )
        try await transport.save([stale, fresh])
        let processor = makeProcessor { now }

        _ = try await processor.processOnce()

        let staleEcho = try XCTUnwrap(try echoes(of: stale.recordName).first)
        XCTAssertEqual(staleEcho.status, .expired)
        XCTAssertEqual(staleEcho.reason, .expired)
        XCTAssertEqual(try echoes(of: fresh.recordName).first?.status, .applied)
    }

    func testSessionRequestsExpireAfterADay() async throws {
        let now = Date()
        let stale = try pendingActionRecord(kind: .sessionInput, entityID: "7", age: 86_400 + 1, now: now)
        var calls = 0
        dispatcher.register(.sessionInput) { _ in
            calls += 1
            return .applied()
        }
        try await transport.save([stale])
        let processor = makeProcessor { now }

        _ = try await processor.processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try echoes(of: stale.recordName).first?.status, .expired)
    }

    // MARK: - Kinds the POC refuses

    func testDKindsAndKindsWithoutAHandlerFailUnsupportedInPOC() async throws {
        let records = try [ActionKind.taskCreate, .targetDone, .targetSnooze, .askAnswer].map {
            try pendingActionRecord(kind: $0, entityID: "1")
        }
        try await transport.save(records)

        _ = try await makeProcessor().processOnce()

        for record in records {
            let echo = try XCTUnwrap(try echoes(of: record.recordName).first, record.recordName)
            XCTAssertEqual(echo.status, .failed, record.recordName)
            XCTAssertEqual(echo.reason, .unsupportedInPOC, record.recordName)
        }
    }

    func testDKindsAreRefusedEvenWithAHandler() async throws {
        var calls = 0
        dispatcher.register(.taskCreate) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .taskCreate)
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try echoes(of: record.recordName).first?.reason, .unsupportedInPOC)
    }

    // MARK: - Backlog after a long sleep (Review focus 5)

    func testFiveHundredPendingRecordsAreProcessedInBatchesOfTwoHundred() async throws {
        let records = try (0..<500).map {
            try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-\($0)")])
        }
        try await transport.save(records)
        let processor = makeProcessor()
        XCTAssertEqual(RelayProcessor.defaultBatchLimit, 200)

        var passes: [RelayProcessor.Pass] = []
        var backlogs: [Int] = []
        repeat {
            passes.append(try await processor.processOnce())
            backlogs.append(processor.relayBacklog)
        } while passes.last?.remaining ?? 0 > 0 && passes.count < 10

        XCTAssertEqual(passes.map(\.handled), [200, 200, 100])
        XCTAssertEqual(backlogs, [300, 100, 0], "relay_backlog counts down to 0")
        let opened = transport.openedEchoes()
        for record in records {
            let echoes = opened.filter { $0.sealed?.wireName == record.recordName }.map { try? decodeAction($0).status }
            XCTAssertEqual(echoes, [.applied], "\(record.recordName) is echoed exactly once")
        }
        // A further pass finds nothing: the token moved past the batch.
        let idle = try await processor.processOnce()
        XCTAssertEqual(idle.handled, 0)
        XCTAssertEqual(idle.remaining, 0)
    }

    // MARK: - Hygiene

    func testHygieneDeletesAgedEchoesAndKeepsPendingAndFresh() async throws {
        let now = Date()
        var applied = ActionRequestPayload(id: "old-echo", kind: .probe, entityID: nil, createdAt: now, deviceID: testPhoneID)
        applied.status = .applied
        let agedEcho = try TestRelayPhone.wireName(applied.recordName)
        try await hubSide.save([try CloudRecordFactory.record(for: applied, modifiedAt: now.addingTimeInterval(-8 * 86_400))])
        let agedPending = try pendingActionRecord(id: "old-pending", kind: .probe, age: 8 * 86_400, now: now)
        let fresh = try pendingActionRecord(id: "fresh", kind: .probe, age: 60, now: now)
        try await transport.save([agedPending, fresh])
        try sidecar.markRelayDone("action-ancient", outcome: "applied", at: now.addingTimeInterval(-9 * 86_400))
        let processor = makeProcessor { now }

        try await processor.runHygieneIfDue()

        let names = Set(try await transport.changes(in: .relay, since: nil).changed.map(\.recordName))
        XCTAssertFalse(names.contains(agedEcho), "an aged echo is deleted")
        XCTAssertTrue(names.contains(agedPending.recordName), "an unprocessed pending record waits for its echo")
        XCTAssertTrue(names.contains(fresh.recordName))
        XCTAssertNil(try sidecar.relayPhase("action-ancient"), "the processed set is pruned past the window")
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.hygieneStampKey))
    }

    // MARK: - One pass at a time (I-3)

    func testConcurrentPassesApplyEachNonIdempotentRecordOnce() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            return .applied()
        }
        let records = try (0..<3).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let processor = makeProcessor()

        let first = Task { try await processor.processOnce() }
        let second = Task { try await processor.processOnce() }
        await awaitHubCondition("a pass is inside the handler") { latch.entries == 1 }
        latch.release()
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(latch.calls.count, 3)
        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 }, "each record is applied once: \(latch.calls)")
    }

    func testTwoProcessorsSharingTheSidecarApplyEachRecordOnce() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            return .applied()
        }
        let records = try (0..<3).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let old = makeProcessor()
        let rebuilt = makeProcessor()

        let first = Task { try await old.processOnce() }
        let second = Task { try await rebuilt.processOnce() }
        await awaitHubCondition("a pass is inside the handler") { latch.entries == 1 }
        latch.release()
        _ = try await first.value
        _ = try await second.value

        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 }, "\(latch.calls)")
        XCTAssertEqual(latch.calls.count, 3)
    }

    func testClaimIsAtomic() throws {
        XCTAssertTrue(try sidecar.claimRelay("action-x", at: Date()))
        XCTAssertFalse(try sidecar.claimRelay("action-x", at: Date()), "a second claim of the same record fails")
        XCTAssertEqual(try sidecar.relayPhase("action-x"), .begun)
    }

    func testCancellationStopsThePassBetweenRecordsNeverMidApply() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            // A cancellation-aware await inside the apply, as GRDB's async
            // write or a sleep would be.
            try Task.checkCancellation()
            return .applied(["comment_id": .integer(1)])
        }
        let records = try (0..<2).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let processor = makeProcessor()

        let pass = Task { try await processor.processOnce() }
        await awaitHubCondition("the first record is inside the handler") { latch.entries == 1 }
        pass.cancel()
        latch.release()

        do {
            _ = try await pass.value
            XCTFail("a cancelled pass throws")
        } catch is CancellationError {}
        XCTAssertEqual(latch.entries, 1, "the record being applied finishes; the next one is left")
        let done = try records.filter { try sidecar.relayPhase($0.plainName) == .done }
        XCTAssertEqual(done.count, 1, "the applied record is done; the other is untouched")
        let echo = try XCTUnwrap(try echoes(of: try XCTUnwrap(done.first).recordName).last)
        XCTAssertEqual(echo.status, .applied, "a stop never reaches into the apply")
        XCTAssertNil(echo.reason)

        // The next pass picks up the record that was left, once.
        _ = try await processor.processOnce()
        XCTAssertEqual(latch.calls.count, 2)
        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 })
    }

    // MARK: - Account reset (I-3, spec §9)

    func testAccountResetKeepsTheLedgerSoADoneRecordIsNotReapplied() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        try sidecar.wipeSyncState(now: Date())
        // Same Apple ID back: the zone is re-fetched and the echo never landed.
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1, "a reset never re-applies a done record")
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
        XCTAssertEqual(try echoes(of: record.recordName).map(\.status), [.applied, .applied], "at most a re-echo")
    }

    // MARK: - Hub addressing (multi-hub spec §3.5)

    func testAnActionForAnotherHubFailsWrongHubIsLedgeredAndReEchoedNeverDispatched() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            return .applied()
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7", hubID: "hub-other")
        try await transport.save([record])
        let processor = makeProcessor()

        _ = try await processor.processOnce()
        try await transport.save([record])          // the phone's pending save wins over the echo
        _ = try await processor.processOnce()

        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.map(\.status), [.failed, .failed])
        XCTAssertEqual(echoes.map(\.reason), [.wrongHub, .wrongHub])
        XCTAssertEqual(echoes.first?.errorMessage, RelayProcessor.wrongHubMessage)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:wrong_hub")
        XCTAssertTrue(latch.calls.isEmpty, "another hub's action is never applied")
    }

    func testAnActionForThisHubOrWithoutAHubIDIsApplied() async throws {
        for (index, hubID) in ["hub-acme", nil].enumerated() {
            let record = try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-\(index)")], hubID: hubID)
            try await transport.save([record])
            _ = try await makeProcessor().processOnce()
            XCTAssertEqual(try echoes(of: record.recordName).first?.status, .applied)
        }
    }
}
