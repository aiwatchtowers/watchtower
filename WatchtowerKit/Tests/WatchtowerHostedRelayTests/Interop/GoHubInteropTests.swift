import CryptoKit
import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import WatchtowerSync
import XCTest

/// The Kit phone against the Go hub on the relay's local stand (relay client Phase 3 Task 13), run by
/// `make relay-interop-kit-hub RELAY=<relay checkout>`: the script starts the stand, the Go side
/// (`internal/hub/interop_kit_test.go`, `TestInterop_KitPhone`) and this class beside it. The two hand
/// off through files in `WT_GO_HUB_INTEROP_DIR` (the Go file lists them); without that variable and
/// `WATCHTOWER_RELAY_INTEROP_URL` the test skips, so neither the Kit suite nor
/// `make relay-interop-kit` needs a hub.
///
/// It uses only Kit pieces the phone app links with (the app's own link screens are not in the Kit):
/// `LinkPayload`, `HostedRelayClient`/`Session`/`Pairing`/`Transport`, `SecureTransport`,
/// `PhoneKeyProvider`, `EnvelopeReplicaOpener`, `ReplicaStore`, `ActionOutbox` and `RelayFeed`.
final class GoHubInteropTests: HostedRelayScenarioCase {
    static let handoffVariable = "WT_GO_HUB_INTEROP_DIR"
    /// A step the Go side answers in seconds; the long ones (the hub's checks) get `goWait`.
    static let stepWait: TimeInterval = 120
    static let goWait: TimeInterval = 300

    override func makeBackend() throws -> RelayBackend {
        _ = try handoffDir()
        return try RelayBackend.standFromEnvironment()
    }

    private func handoffDir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment[Self.handoffVariable], !dir.isEmpty else {
            throw XCTSkip("\(Self.handoffVariable) is not set: run `make relay-interop-kit-hub RELAY=<relay checkout>`")
        }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    // MARK: - The run

    func testKitPhoneLinksDrivesAndUnlinksTheGoHub() async throws {
        let handoff = Handoff(dir: try handoffDir())
        do {
            try await linkDriveAndUnlink(handoff)
        } catch {
            // The Go side stops waiting; only the step's name goes in the file.
            handoff.write("kit.fail", handoff.step)
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    private func linkDriveAndUnlink(_ handoff: Handoff) async throws {
        // 1. The v4 code.
        handoff.step = "parse"
        let text = try await handoff.wait("pair.url", Self.goWait)
        guard let url = URL(string: text), case .success(let code) = LinkPayload.parse(url) else {
            return XCTFail("pair.url is not a link code")
        }
        XCTAssertEqual(code.v, 4)
        XCTAssertTrue(code.offersRelay)
        XCTAssertFalse(code.offersCloudKit, "a headless hub links over the relay only")
        let mac = try XCTUnwrap(code.relayDeviceID)
        let hubAuth = try XCTUnwrap(code.relayAuthPub.flatMap(WireBytes.fromBase64URL))

        // 2. A paying phone (attestation is off on the stand; FakeAppAttest's bytes ride along).
        handoff.step = "register"
        let phone = try await makeClient(kind: .phone, seed: 1)
        try await pay(phone)

        // 3. The slot and the hello naming the phone's relay id.
        handoff.step = "hello"
        let link = try PhoneLink(code: code)
        let session = HostedRelaySession(client: phone)
        let pairing = HostedRelayPairing(session: session)
        let first = try await pairing.open(mac: mac).slot
        let store = try TransportStore.inMemory()
        var pairT: HostedRelayTransport? = try HostedRelayTransport(
            session: session, store: store, macDeviceID: mac, mode: .pairing(slot: first))
        let hello = DeviceHello(
            device: link.device(nonce: code.nonce, unlinked: false),
            signingKey: WireBytes.base64URL(link.identity.signing.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(link.identity.agreement.publicKey.rawRepresentation),
            relayDeviceID: phone.deviceID)
        try await link.secure(over: try XCTUnwrap(pairT)).save([try CloudRecordFactory.record(for: hello, modifiedAt: Date())])

        // 4. The awaiting keybox, SAS v2, the owner's confirmation, the keys.
        handoff.step = "sas"
        let awaiting = try await link.keybox(in: try XCTUnwrap(pairT), within: Self.stepWait) {
            $0.grant.awaitingConfirmation == true && $0.grant.confirmNonce != nil
        }
        XCTAssertEqual(awaiting.grant.linkCodeTag, KeyDerivation.linkCodeTag(linkNonce: link.linkNonce))
        handoff.write("pair.sas", try link.sas(confirmNonce: try XCTUnwrap(awaiting.grant.confirmNonce)))
        _ = try await handoff.wait("confirmed", Self.stepWait)
        handoff.step = "keys"
        let linked = try await link.keybox(in: try XCTUnwrap(pairT), within: Self.stepWait) {
            $0.grant.linked && $0.keys != nil
        }
        try link.merge(try XCTUnwrap(linked.keys))
        pairT = nil

        // 5. Try Again: a new slot for the same Mac replaces the first; no hello in it, vouch, promote.
        handoff.step = "try_again"
        let retry = try await pairing.open(mac: mac).slot
        XCTAssertNotEqual(retry, first)
        try await expectServerCode(.notFound, "promote of the replaced slot") { try await pairing.promote(slot: first) }
        try await expectServerCode(.hubNotVouched, "promote before the vouch") { try await pairing.promote(slot: retry) }
        try await pairing.vouch(hubDeviceID: mac, authPub: hubAuth)
        try await pairing.promote(slot: retry)

        // 6. The data zone through the hub-mode transport: the grant, the heartbeat, every slice opens.
        handoff.step = "data_zone"
        let hubT = try HostedRelayTransport(session: session, store: store, macDeviceID: mac, mode: .hub)
        let secure = link.secure(over: hubT)
        let grantBox = try await link.keybox(in: hubT, within: Self.stepWait) { $0.grant.linked }
        XCTAssertTrue(grantBox.grant.runsOrderedActions, "the Go hub runs ordered actions")
        XCTAssertEqual(grantBox.grant.relayDeviceID, mac)
        let kinds = try await link.openEveryDataRecord(hubT)
        XCTAssertTrue(kinds.contains(SliceKind.deviceGrant.rawValue), "kinds \(kinds.sorted())")
        XCTAssertTrue(kinds.contains(SliceKind.heartbeat.rawValue), "kinds \(kinds.sorted())")

        // 7. Three ordered actions with canaries; the feed reads the applied echoes and deletes them.
        handoff.step = "actions"
        let outbox = ActionOutbox(
            transport: secure, store: link.replica, deviceID: link.deviceID.uuidString, route: .hostedRelay(macDeviceID: mac))
        await outbox.setHubID(code.hubID)
        try await outbox.enableOrderedActions()
        let applied = OSAllocatedUnfairLock(initialState: 0)
        await outbox.setAppliedObserver { _ in applied.withLock { $0 += 1 } }
        let marks = (1...3).map { _ in "wt-canary-kit-" + UUID().uuidString.lowercased() }
        for mark in marks {
            try await outbox.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(mark)])
        }
        _ = try await outbox.flush()
        let pull: @Sendable () async throws -> Void = { try await hubT.pull() }
        let feed = RelayFeed(transport: secure, store: link.replica, outbox: outbox, pull: pull)
        try await poll(within: Self.stepWait, "three applied echoes") {
            try await feed.pollOnce()
            return applied.withLock { $0 } == 3
        }

        // 8. The grant's keys merged, the epoch acknowledged.
        handoff.step = "epoch_ack"
        let grantKeys = try XCTUnwrap(grantBox.keys)
        try link.merge(grantKeys)
        let queued = try await outbox.enqueueEpochAck(epoch: grantKeys.epoch)
        XCTAssertTrue(queued)
        _ = try await outbox.flush()

        // 9. The hub's checks.
        handoff.step = "go_checks"
        let report: [String: Any] = ["relay_device_id": phone.deviceID, "first_slot": first, "retry_slot": retry, "marks": marks]
        handoff.write("actions.done", String(bytes: try JSONSerialization.data(withJSONObject: report), encoding: .utf8) ?? "")
        _ = try await handoff.wait("go.ok", Self.goWait)

        // 10. Unlink (R14): the farewell, flushed, then remove_slot.
        handoff.step = "unlink"
        try await secure.save([try CloudRecordFactory.record(for: link.device(nonce: nil, unlinked: true), modifiedAt: Date())])
        try await hubT.pull()
        // The hub reads it before remove_slot: an unslotted hub is unvouched and cannot read the mailbox.
        handoff.write("farewell.sent", "")
        _ = try await handoff.wait("farewell.ok", Self.goWait)
        try await pairing.removeSlot(mac: mac)
        let afterRemove = try await pairing.accountState().macs
        XCTAssertFalse(afterRemove.contains(mac))
        handoff.write("unlinked", "")
        _ = try await handoff.wait("unlink.ok", Self.goWait)

        // 11. The slot is free again: add_slot of the same Mac (a lapsed vouch is renewed once).
        handoff.step = "readd"
        var add = Relay_V1_AddMacSlot()
        add.macDeviceID = mac
        do {
            try await phone.addSlot(add)
        } catch HostedRelayError.server(code: .hubNotVouched, _) {
            try await pairing.vouch(hubDeviceID: mac, authPub: hubAuth)
            try await phone.addSlot(add)
        }
        let afterAdd = try await pairing.accountState().macs
        XCTAssertTrue(afterAdd.contains(mac))
        XCTAssertLessThanOrEqual(afterAdd.count, HostedRelayLimits.maxMacSlots)
        handoff.write("readded", "")
        _ = try await handoff.wait("go.done", Self.goWait)
        handoff.step = "done"
    }

    // MARK: - Helpers

    private func expectServerCode(
        _ code: Relay_V1_ErrorCode,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
            XCTFail("\(what): no refusal, expected \(code)", file: file, line: line)
        } catch HostedRelayError.server(let got, _) {
            XCTAssertEqual(got, code, what, file: file, line: line)
        }
    }

    /// Runs `body` every second until it returns true; throws when `limit` passes first.
    private func poll(within limit: TimeInterval, _ what: String, _ body: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            if try await body() { return }
            guard Date() < deadline else { throw GoHubInteropFailure.timedOut(what) }
            try await Task.sleep(for: .seconds(1))
        }
    }
}

enum GoHubInteropFailure: Error, Equatable {
    case timedOut(String)
    case goFailed(String)
}

/// The handoff folder: files written whole (temp + rename), read by polling.
private final class Handoff: @unchecked Sendable {
    let dir: URL
    /// The step running now, written to kit.fail when the run throws.
    var step = "start"

    init(dir: URL) {
        self.dir = dir
    }

    func write(_ name: String, _ body: String) {
        let tmp = dir.appendingPathComponent(".\(name).tmp")
        do {
            try Data(body.utf8).write(to: tmp)
            _ = try FileManager.default.replaceItemAt(dir.appendingPathComponent(name), withItemAt: tmp)
        } catch {
            XCTFail("handoff \(name) not written: \(error)")
        }
    }

    /// The contents of `name` once the hub wrote it; `go.fail` (a hub check failed) throws at once.
    func wait(_ name: String, _ limit: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                return String(bytes: data, encoding: .utf8) ?? ""
            }
            if let failed = try? Data(contentsOf: dir.appendingPathComponent("go.fail")) {
                throw GoHubInteropFailure.goFailed(String(bytes: failed, encoding: .utf8) ?? "")
            }
            guard Date() < deadline else { throw GoHubInteropFailure.timedOut(name) }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// The phone's side of one link: its keys, the hub's keys from the code, the replica and the sealing.
private struct PhoneLink {
    let keys = InMemoryPhoneKeyStore()
    let identity: DeviceIdentityKeys
    let hubID: String
    let hubUUID: UUID
    let linkNonce: Data
    let hubSigning: Curve25519.Signing.PublicKey
    let hubAgreement: Curve25519.KeyAgreement.PublicKey
    let opener: EnvelopeReplicaOpener
    let replica: ReplicaStore
    let provider: PhoneKeyProvider

    var deviceID: UUID {
        identity.deviceID
    }

    init(code: LinkPayload) throws {
        identity = try keys.identity()
        hubID = code.hubID
        hubUUID = try WireBytes.hubUUID(code.hubID)
        linkNonce = try XCTUnwrap(WireBytes.fromBase64URL(code.nonce))
        hubSigning = try Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(WireBytes.fromBase64URL(code.hubSigningKey)))
        hubAgreement = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(WireBytes.fromBase64URL(code.hubAgreementKey)))
        // The link before the confirmation: the hub's keys and the nonce (the hello seals with them).
        try keys.saveHubLink(HubLinkKeys(
            hubID: hubID, hubSigningKey: hubSigning.rawRepresentation, hubAgreementKey: hubAgreement.rawRepresentation,
            linkNonce: linkNonce))
        opener = EnvelopeReplicaOpener(hubID: hubID, deviceID: identity.deviceID, keys: keys)
        let replica = try ReplicaStore.inMemory(opener: opener)
        self.replica = replica
        let seq = SeqAllocator(load: { try replica.envelopeSeqCeiling() }, store: { try replica.setEnvelopeSeqCeiling($0) })
        provider = try PhoneKeyProvider(store: keys, hubID: hubID, seq: seq)
    }

    func secure(over inner: HostedRelayTransport) -> SecureTransport {
        SecureTransport(inner: inner, keys: provider, rollback: replica)
    }

    func device(nonce: String?, unlinked: Bool) -> DevicePayload {
        DevicePayload(
            deviceID: deviceID.uuidString, name: "Test Phone", model: "iPhone18,1", appVersion: "0.0.0-test", scope: .private,
            userRecordName: "", linkNonce: nonce, unlinked: unlinked ? true : nil, typingRequested: false, startSessions: true,
            updatedAt: Date())
    }

    /// SAS v2 with the hub's argument order (the phone app's `ScannedHubKeys.code`).
    func sas(confirmNonce text: String) throws -> String {
        let confirm = try XCTUnwrap(WireBytes.fromBase64URL(text))
        XCTAssertEqual(confirm.count, KeyDerivation.confirmNonceLength)
        return KeyDerivation.sas(
            hubID: hubUUID, linkNonce: linkNonce, hubSigning: hubSigning, hubAgreement: hubAgreement,
            deviceSigning: identity.signing.publicKey, deviceAgreement: identity.agreement.publicKey, confirmNonce: confirm)
    }

    /// Pulls `transport` every second until this phone's keybox in its data lane satisfies `wanted`. A pull the relay
    /// refuses (not a reader yet) is retried.
    func keybox(
        in transport: HostedRelayTransport, within limit: TimeInterval, _ wanted: (Keybox) -> Bool
    ) async throws -> Keybox {
        let name = Keybox.recordName(deviceID: deviceID.uuidString)
        let deadline = Date().addingTimeInterval(limit)
        while true {
            do {
                try await transport.pull()
                let batch = try await transport.changes(in: .data, since: nil)
                if let record = batch.changed.last(where: { $0.recordName == name }) {
                    let box = try opener.openKeybox(wireName: record.recordName, envelope: record.payload)
                    if wanted(box) { return box }
                }
            } catch let error as HostedRelayError {
                if case .server(code: .forbidden, _) = error {} else { throw error }
            }
            guard Date() < deadline else { throw GoHubInteropFailure.timedOut("keybox") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// The keybox's keys joined to the stored link (the phone app's `HubLinkKeys.adding`).
    func merge(_ boxKeys: KeyboxKeys) throws {
        func key(_ text: String) throws -> Data {
            let bytes = try XCTUnwrap(WireBytes.fromBase64URL(text))
            XCTAssertEqual(bytes.count, 32)
            return bytes
        }
        var link = try XCTUnwrap(try keys.hubLink(hubID))
        var byEpoch = Dictionary(link.epochs.map { ($0.epoch, $0) }) { _, new in new }
        if let previous = boxKeys.previousEpoch, let data = boxKeys.previousDataKey, let alert = boxKeys.previousAlertKey {
            byEpoch[previous] = EpochKeys(epoch: previous, dataKey: try key(data), alertKey: try key(alert))
        }
        byEpoch[boxKeys.epoch] = EpochKeys(epoch: boxKeys.epoch, dataKey: try key(boxKeys.dataKey), alertKey: try key(boxKeys.alertKey))
        link.metaKey = try key(boxKeys.metaKey)
        link.epochs = byEpoch.values.sorted { $0.epoch < $1.epoch }
        try keys.saveHubLink(link)
    }

    /// Opens every record of the hub's data zone (spec §13 E2E (3)); returns the kinds. Signals are not envelopes.
    func openEveryDataRecord(_ transport: HostedRelayTransport) async throws -> Set<String> {
        try await transport.pull()
        let batch = try await transport.changes(in: .data, since: nil)
        var kinds: Set<String> = []
        for record in batch.changed where !record.recordName.hasPrefix("\(WireKind.signal)-") {
            let frame = try opener.open(wireName: record.recordName, envelope: record.payload)
            kinds.insert(frame.kind)
            if frame.kind == SliceKind.heartbeat.rawValue {
                _ = try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: frame.payload)
            }
        }
        return kinds
    }
}
