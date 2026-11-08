import CryptoKit
import GRDB
import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// `ActionOutbox.mergeKeybox` (relay client Phase 5, Task 8 fix round 1b): a keybox merge reseals this phone's own
/// rows sealed in an epoch the merge drops, with the keys held before the merge, so every counted Not delivered row
/// stays listed; a `queued`/`sent` row past its key is listed Not delivered and never sent (F7).
final class ActionOutboxResealTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var hubID: String { TestE2E.hubID.uuidString }

    private struct Phone {
        let keys: InMemoryPhoneKeyStore
        let inner: InMemoryCloudTransport
        let recorder: RecordingConditionalTransport
        let secure: SecureTransport
        let store: ReplicaStore
        let outbox: ActionOutbox
        let clock: OSAllocatedUnfairLock<Date>

        var now: Date { clock.withLock { $0 } }
        func advance(by seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// The paired phone with an offer and no epoch yet, ordered, on a movable clock shared by its key store.
    private func makePhone() async throws -> Phone {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let now: @Sendable () -> Date = { clock.withLock { $0 } }
        let keys = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity, now: now)
        try keys.saveHubLink(HubLinkKeys(
            hubID: hubID, hubSigningKey: TestE2E.hubSigningKey.publicKey.rawRepresentation,
            hubAgreementKey: TestE2E.hubAgreementKey.publicKey.rawRepresentation, linkNonce: TestE2E.linkNonce,
            metaKey: TestE2E.metaKey.withUnsafeBytes { Data($0) }, offeredKX: EphemeralKey.generate()))
        let inner = InMemoryCloudTransport()
        let recorder = RecordingConditionalTransport(inner: inner)
        let secure = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: recorder)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let outbox = ActionOutbox(transport: secure, store: store, deviceID: TestE2E.deviceID.uuidString, now: now)
        try await outbox.enableOrderedActions()
        await outbox.setHubID(hubID)
        return Phone(keys: keys, inner: inner, recorder: recorder, secure: secure, store: store, outbox: outbox, clock: clock)
    }

    /// The hub's keybox for `epoch`: a fresh `hub_eph`, answering the phone's offer (or its current key).
    private func keybox(_ phone: Phone, epoch: UInt32) throws -> KeyboxKeys {
        let link = try XCTUnwrap(phone.keys.hubLink(hubID))
        let device = try XCTUnwrap(link.offeredKX ?? link.currentKX)
        func key(_ label: UInt8) -> String { WireBytes.base64URL(Data(repeating: label, count: 32)) }
        return KeyboxKeys(
            epoch: epoch, dataKey: key(UInt8(truncatingIfNeeded: epoch)), alertKey: key(0xA0),
            metaKey: WireBytes.base64URL(TestE2E.metaKey.withUnsafeBytes { Data($0) }),
            relayKX: KeyboxRelayKX(
                hubPub: WireBytes.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                devicePub: WireBytes.base64URL(device.publicKey)))
    }

    @discardableResult
    private func merge(_ phone: Phone, epoch: UInt32) async throws -> KeyboxMerge? {
        try await phone.outbox.mergeKeybox(try keybox(phone, epoch: epoch), into: phone.keys, hubID: hubID, now: phone.now)
    }

    private func listed(_ phone: Phone, _ id: String) throws -> PendingAction? {
        try phone.store.pendingActions().first { $0.id == id }
    }

    private func epoch(of row: PendingAction?, _ phone: Phone) throws -> UInt32? {
        let stored = try phone.store.outboxRows([.queued, .sent, .settled, .undelivered]).first { $0.actionID == row?.id }
        return try stored.map { try Envelope.parse($0.envelope).header.epoch }
    }

    // MARK: - Tests

    func testAnUndeliveredRowStaysListedAcrossManyRotations() async throws {
        let phone = try await makePhone()
        try await merge(phone, epoch: 1)
        let id = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        await phone.outbox.drain()
        try phone.store.markUndelivered(actionIDs: [id], reason: .refused, message: "Not delivered to your Mac.")

        for epoch: UInt32 in 2...20 {
            phone.advance(by: 7 * day)
            try await merge(phone, epoch: epoch)
        }

        let link = try XCTUnwrap(phone.keys.hubLink(hubID))
        XCTAssertFalse(link.epochs.contains { $0.epoch == 1 }, "the row's first epoch left retention long ago")
        let row = try XCTUnwrap(listed(phone, id), "still listed")
        XCTAssertEqual(row.delivery, .undelivered)
        XCTAssertEqual(row.action.kind, .targetDone)
        let counts = try await phone.store.reader.read { try phone.store.outboxCounts(from: $0) }
        XCTAssertEqual(counts.undelivered, 1, "the count and the list agree")
        let sealedIn = try XCTUnwrap(try epoch(of: row, phone))
        XCTAssertTrue(link.epochs.contains { $0.epoch == sealedIn }, "it sits in an epoch the phone holds")
        XCTAssertTrue(try phone.store.stagedReseals().isEmpty)
    }

    /// F7 with a phone back after 8+ rotations: one merge jumps many epochs and drops the row's epoch. The row is
    /// resealed first, so it is listed, Not delivered, and never sent.
    func testAnF7ReturnShowsTheRowNotDeliveredAndListed() async throws {
        let phone = try await makePhone()
        try await merge(phone, epoch: 1)
        let id = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try listed(phone, id)?.delivery, .sent)
        phone.advance(by: 7 * day)
        try await merge(phone, epoch: 2)
        let writes = await phone.recorder.conditionalSaves.count

        // Away for ten weeks: the first merge on return jumps to epoch 12.
        phone.advance(by: 70 * day)
        try await merge(phone, epoch: 12)

        let link = try XCTUnwrap(phone.keys.hubLink(hubID))
        XCTAssertEqual(link.epochs.map(\.epoch), [2, 12], "epoch 1 is gone")
        let row = try XCTUnwrap(listed(phone, id), "listed")
        XCTAssertEqual(row.delivery, .undelivered)
        XCTAssertEqual(row.undeliveredReason, .refused)
        XCTAssertEqual(try epoch(of: row, phone), 12)
        _ = try await phone.outbox.flush()
        try await phone.outbox.resendFrom(1)
        let after = await phone.recorder.conditionalSaves
        XCTAssertFalse(
            after.dropFirst(writes).flatMap(\.names).contains(try phone.secure.wireName(
                plain: ActionRequestPayload.orderedRecordName(deviceID: TestE2E.deviceID, actionSeq: 1), zone: .relay)),
            "never sent")
    }

    /// A row still in an epoch the merge keeps is not touched.
    func testARowInAKeptEpochKeepsItsBytes() async throws {
        let phone = try await makePhone()
        try await merge(phone, epoch: 1)
        let id = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await phone.outbox.flush()
        let before = try XCTUnwrap(phone.store.outboxRows([.sent]).first { $0.actionID == id })

        phone.advance(by: day)
        try await merge(phone, epoch: 2)

        let after = try XCTUnwrap(phone.store.outboxRows([.sent]).first { $0.actionID == id })
        XCTAssertEqual(after.envelope, before.envelope)
        XCTAssertEqual(after.delivery, .sent)
    }

    /// A kill after the stage leaves the old keys and the old rows; a kill after the save leaves the stage, which the
    /// next merge applies. Each re-run is idempotent.
    func testAKillBetweenTheResealAndTheSave() async throws {
        let phone = try await makePhone()
        try await merge(phone, epoch: 1)
        let id = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        await phone.outbox.drain()
        try phone.store.markUndelivered(actionIDs: [id], reason: .refused, message: "Not delivered to your Mac.")
        phone.advance(by: 7 * day)
        try await merge(phone, epoch: 2)
        phone.advance(by: 70 * day)
        let box = try keybox(phone, epoch: 12)
        let link = try XCTUnwrap(phone.keys.hubLink(hubID))
        let rowBefore = try XCTUnwrap(phone.store.outboxRows([.undelivered]).first)
        let merged = try link.merging(
            box, identity: TestE2E.deviceIdentity, hubID: TestE2E.hubID, deviceID: TestE2E.deviceID, now: phone.now)

        // Killed after the stage, before the save.
        try await phone.outbox.stageOwnReseals(
            from: link, to: merged.keys, identity: TestE2E.deviceIdentity, hub: TestE2E.hubID, device: TestE2E.deviceID,
            now: phone.now)
        XCTAssertEqual(try phone.store.stagedReseals().count, 1)
        XCTAssertEqual(try phone.keys.hubLink(hubID), link, "the old keys")
        XCTAssertEqual(try phone.store.outboxRows([.undelivered]).first?.envelope, rowBefore.envelope, "the old row")
        XCTAssertNotNil(try listed(phone, id))

        // The re-run, killed after the save, before the promote.
        try await phone.outbox.stageOwnReseals(
            from: link, to: merged.keys, identity: TestE2E.deviceIdentity, hub: TestE2E.hubID, device: TestE2E.deviceID,
            now: phone.now)
        XCTAssertEqual(try phone.store.stagedReseals().count, 1, "staged again, not twice")
        _ = try phone.keys.updateHubLink(hubID) { _ in merged.keys }
        XCTAssertEqual(try phone.store.outboxRows([.undelivered]).first?.envelope, rowBefore.envelope)

        // The next merge (they run after every fetch) applies the stage first.
        try await phone.outbox.mergeKeybox(box, into: phone.keys, hubID: hubID, now: phone.now)

        XCTAssertTrue(try phone.store.stagedReseals().isEmpty)
        let row = try XCTUnwrap(listed(phone, id))
        XCTAssertEqual(try epoch(of: row, phone), 12)
        XCTAssertEqual(row.delivery, .undelivered)
    }

    func testALockedKeychainDuringTheResealChangesNothing() async throws {
        let phone = try await makePhone()
        try await merge(phone, epoch: 1)
        let id = try await phone.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        await phone.outbox.drain()
        try phone.store.markUndelivered(actionIDs: [id], reason: .refused, message: "Not delivered to your Mac.")
        phone.advance(by: 7 * day)
        try await merge(phone, epoch: 2)
        phone.advance(by: 70 * day)
        let box = try keybox(phone, epoch: 12)
        let link = try XCTUnwrap(phone.keys.hubLink(hubID))
        let rowBefore = try XCTUnwrap(phone.store.outboxRows([.undelivered]).first)

        phone.keys.isLocked = true
        do {
            try await phone.outbox.mergeKeybox(box, into: phone.keys, hubID: hubID, now: phone.now)
            XCTFail("locked")
        } catch SecureTransportError.keysUnavailable {}
        phone.keys.isLocked = false

        XCTAssertEqual(try phone.keys.hubLink(hubID), link)
        XCTAssertEqual(try phone.store.outboxRows([.undelivered]).first?.envelope, rowBefore.envelope)
        XCTAssertTrue(try phone.store.stagedReseals().isEmpty)

        try await phone.outbox.mergeKeybox(box, into: phone.keys, hubID: hubID, now: phone.now)
        XCTAssertEqual(try epoch(of: try listed(phone, id), phone), 12, "after unlock the merge runs whole")
    }
}
