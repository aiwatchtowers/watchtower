import CryptoKit
import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Relay keys rotate end to end (relay client Phase 5 Task 11), run by
/// `make relay-interop-kit-hub RELAY=<relay checkout> RELAY_INTEROP_ROTATION=1` beside the Go side's
/// `TestInterop_KitPhoneRotates` (`internal/hub/interop_kit_test.go` lists the handoff files). The Go hub is a Mac's
/// desktop host on a clock it moves, rotating at a daemon cycle. Two Kit phones link over iCloud and move the hub to the
/// relay (the calls `RelayUpgrader` makes, as the switch run does); every keybox goes through the app's merge
/// (`ActionOutbox.mergeKeybox`, the real `HubLinkKeys.merging`) over an in-memory key store on the hub's clock. The
/// first phone offers ephemeral keys on the relay route (`withOffer` on every ack); the second never offers.
extension KitGoHubInteropTests {
    /// Set to 1 by `RELAY_INTEROP_ROTATION=1` (with `WT_GO_HUB_INTEROP_DESKTOP=1`): the handoff folder is the rotation
    /// run's, and the switch run skips.
    static let rotationVariable = "WT_GO_HUB_INTEROP_ROTATION"
    /// One rotation's move of the hub's clock (`rotationJump` on the Go side).
    static let rotationJump: TimeInterval = 8 * 86_400

    func testKitPhoneRotatesRelayKeys() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.desktopVariable] == "1", env[Self.rotationVariable] == "1" else {
            throw XCTSkip("\(Self.rotationVariable) is not 1: the rotation runs only in its own desktop host's run")
        }
        let handoff = Handoff(dir: try handoffDir())
        do {
            try await rotateRelayKeys(handoff)
        } catch {
            handoff.write("kit.fail", handoff.step)
            throw error
        }
    }

    private func rotateRelayKeys(_ handoff: Handoff) async throws {
        handoff.step = "ck_url"
        _ = try await handoff.wait(LoopbackCloudEndpoint.handoffFile, Self.goWait)
        let endpoint = try LoopbackCloudEndpoint.read(fromHandoff: handoff.dir)
        let clock = HubClock()
        handoff.step = "link"
        let phoneA = try await ICloudPhone.link(handoff, endpoint: endpoint, files: ("pair.url", "pair.sas", "confirmed"), now: clock.closure)
        handoff.step = "link_static"
        let phoneB = try await ICloudPhone.link(handoff, endpoint: endpoint, files: ("free.url", "free.sas", "free.confirmed"), now: clock.closure)

        handoff.step = "r1"
        var rig = try await moveToRelay(phoneA: phoneA, phoneB: phoneB, clock: clock)
        try await stepEphemeral(handoff, &rig)
        try await stepAway(handoff, &rig)
        try await stepLongAway(handoff, &rig)
        try await stepICloudAndBack(handoff, &rig)
        try await stepLapse(handoff, &rig)
        try await stepRelayAnswers(handoff, rig)
        handoff.step = "done"
        _ = try await handoff.wait("go.ok", Self.goWait)
        await rig.a.stop()
        await rig.b.stop()
    }

    // MARK: Step 1: on the relay

    /// Both phones pay, prove their relay ids, vouch and take the Mac's slot; the first asks for the relay, and both
    /// follow `transport_switched`. The switch's keybox is static (no offer yet): the offering phone acks it with
    /// `next_kx`, the static one without.
    private func moveToRelay(phoneA: ICloudPhone, phoneB: ICloudPhone, clock: HubClock) async throws -> RotationRig {
        let grant = try await phoneA.keybox(over: phoneA.cloud) { $0.grant.linked }.grant
        let mac = try XCTUnwrap(grant.relayDeviceID)
        let hubAuth = try XCTUnwrap(grant.relayAuthPub.flatMap(WireBytes.fromBase64URL))
        let a = try await KitFollower(phone: phoneA, canUseRelay: .yes, keys: FollowerKeys(offers: true, clock: clock))
        let b = try await KitFollower(phone: phoneB, canUseRelay: .yes, keys: FollowerKeys(offers: false, clock: clock))
        var relays: [HostedRelayTransport] = []
        var relayIDs: [String] = []
        for (seed, phone, follower) in [(UInt8(1), phoneA, a), (UInt8(2), phoneB, b)] {
            let client = try await makeClient(kind: .phone, seed: seed)
            try await pay(client)
            let signer = try backend.signer(seed: seed)
            let proof = try RelayIDProof.sign(authPub: signer.publicKey, hubID: phone.link.hubUUID, deviceID: phone.link.deviceID) {
                try signer.sign($0)
            }
            try await phone.saveRetrying([try CloudRecordFactory.record(
                for: phone.link.device(nonce: nil, unlinked: false, relay: proof), modifiedAt: Date())])
            let session = HostedRelaySession(client: client)
            let pairing = HostedRelayPairing(session: session)
            try await pairing.vouch(hubDeviceID: mac, authPub: hubAuth)
            try await pairing.addSlot(mac: mac)
            let relayT = try HostedRelayTransport(session: session, store: try TransportStore.inMemory(), macDeviceID: mac, mode: .hub)
            try await poll(within: Self.stepWait, "the first data-zone read") {
                do {
                    try await relayT.pull(only: [.data])
                    return true
                } catch HostedRelayError.server(code: .forbidden, _) {
                    return false
                }
            }
            await follower.attachRelay(relayT, mac: mac)
            relays.append(relayT)
            relayIDs.append(client.deviceID)
        }
        let requestID = UUID().uuidString
        _ = try await a.outbox.enqueueSwitchRequest(target: .relay, id: requestID)
        _ = try await a.outbox.flush()
        try await a.writeRequestCopy(target: .relay, id: requestID, on: .relay)
        for follower in [a, b] {
            try await follower.pollUntil(within: Self.stepWait, "the move to the relay") { await $0.route == .relay }
        }
        let rig = RotationRig(a: a, b: b, phoneA: phoneA, phoneB: phoneB, relayA: relays[0], mac: mac, hubAuth: hubAuth,
                              clock: clock, relayIDs: (relayIDs[0], relayIDs[1]))
        let e1 = try phoneA.newestEpoch()
        XCTAssertEqual(try phoneB.newestEpoch(), e1)
        // The switch's keybox: dev_kx, no relay_kx (no offer was out yet).
        let logA = await a.keyboxLog
        XCTAssertEqual(logA.keyed[e1], false, "the switch's keybox carries no relay_kx")
        let offer = try XCTUnwrap(try rig.linkA().offeredKX, "the offering phone acked with next_kx")
        XCTAssertFalse(try rig.linkB().hasEphemeralState, "the static phone never offers")
        let answer = try await rig.report("r1", RotReport(rig: rig, epoch: e1, offer: offer.publicKey), into: "r1.ok")
        clock.set(answer.offset)
        return rig
    }

    // MARK: Steps 2 and 6: one rotation

    /// The hub rotates once: the offering phone opens the keybox with its offer, derives, promotes and offers again;
    /// one action of each phone is applied once and its echo opens; the static phone's keybox stays static.
    private func stepEphemeral(_ handoff: Handoff, _ rig: inout RotationRig) async throws {
        handoff.step = "r2"
        let offer = try XCTUnwrap(try rig.linkA().offeredKX)
        let e1 = try rig.phoneA.newestEpoch()
        let answer = try await rig.report("r1.ready", RotReport(rig: rig, epoch: e1, offer: offer.publicKey), into: "r2.go")
        rig.clock.set(answer.offset)
        let fetchA = try await rig.a.fetchKeybox(atLeast: e1 + 1)
        let e2 = fetchA.keys.epoch
        XCTAssertEqual(e2, e1 + 1)
        let kx = try XCTUnwrap(fetchA.keys.relayKX, "the rotation's keybox names the offer")
        XCTAssertEqual(WireBytes.fromBase64URL(kx.devicePub), offer.publicKey, "relay_kx.device_pub is the offer")
        try checkPromoted(fetchA, offer: offer, oldCurrent: nil)
        try checkPrevious(fetchA)
        let fetchB = try await rig.b.fetchKeybox(atLeast: e2)
        XCTAssertNil(fetchB.keys.relayKX, "the static phone's keybox is static")
        XCTAssertFalse(try rig.linkB().hasEphemeralState)

        let markA = try await rig.send(rig.a, "wt-canary-rot2-")
        let markB = try await rig.send(rig.b, "wt-canary-rot2s-")
        try await rig.settle(rig.a, "the offering phone's echo in epoch \(e2)")
        try await rig.settle(rig.b, "the static phone's echo in epoch \(e2)")
        var report = RotReport(rig: rig, epoch: e2, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey)
        report.marks = [markA]
        report.freeMarks = [markB]
        report.prevKX = fetchA.keys.previousRelayKX != nil
        try await rig.checkKeyboxLogs()
        _ = try await rig.report("r2", report, into: "r2.ok")
    }

    // MARK: Steps 3 and 6: one rotation away

    /// The hub rotates while the offering phone is away. The alert pushed meanwhile opens with the alert copy of the
    /// keys alone (a locked phone); the action it sealed before the rotation is accepted after it; back, the keybox
    /// opens with the outstanding offer and carries `previous_relay_kx` for the epoch it left.
    private func stepAway(_ handoff: Handoff, _ rig: inout RotationRig) async throws {
        handoff.step = "r3"
        let e2 = try rig.phoneA.newestEpoch()
        let offer = try XCTUnwrap(try rig.linkA().offeredKX)
        let current = try XCTUnwrap(try rig.linkA().currentKX)
        // Made "after the rotation" on the hub's clock, so it is within the age window when it arrives; sealed now.
        let held = try await rig.heldOutbox(ahead: Self.rotationJump)
        let heldMark = "wt-canary-rot3-" + UUID().uuidString.lowercased()
        try await held.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(heldMark)])
        let heldRow = try XCTUnwrap(try rig.phoneA.replica.outboxRows([.queued]).last)
        XCTAssertEqual(heldRow.epoch, e2)
        var report = RotReport(rig: rig, epoch: e2, offer: offer.publicKey)
        report.heldMark = heldMark
        report.heldSeq = heldRow.actionSeq
        let answer = try await rig.report("r3.ready", report, into: "r3.go")
        rig.clock.set(answer.offset)

        // The locked phone: only the alert copy of the keys (`alert.<id>`), the new epoch not merged yet.
        handoff.step = "r3_push"
        let push = try XCTUnwrap(answer.push.flatMap(WireBytes.fromBase64URL), "the hub pushed the alert")
        XCTAssertEqual(try Envelope.parse(push).header.epoch, e2, "the push is sealed in the epoch the phone acked")
        let material = try XCTUnwrap(try rig.phoneA.link.keys.alertMaterial(rig.phoneA.link.hubID))
        XCTAssertFalse(material.epochs.contains { $0.epoch > e2 }, "the alert copy holds no newer epoch yet")
        let alert = AlertOpener(material: material).open(wireName: AlertSource.inlineWireName, envelope: push)
        XCTAssertEqual(alert?.key, "ask-rot", "the locked phone opens the push across the rotation")

        handoff.step = "r3_held"
        await held.releaseFlushes()
        _ = try await held.flush()
        try await rig.settle(rig.a, "the echo of the action sealed in epoch \(e2)")
        let fetchA = try await rig.a.fetchKeybox(atLeast: e2 + 1)
        let e3 = fetchA.keys.epoch
        XCTAssertEqual(e3, e2 + 1)
        XCTAssertEqual(fetchA.keys.relayKX.flatMap { WireBytes.fromBase64URL($0.devicePub) }, offer.publicKey)
        try checkPromoted(fetchA, offer: offer, oldCurrent: current)
        try checkPrevious(fetchA)
        XCTAssertNotNil(fetchA.keys.previousRelayKX, "the hub holds epoch \(e2)'s row: previous_relay_kx is sent")
        let fetchB = try await rig.b.fetchKeybox(atLeast: e3)
        XCTAssertNil(fetchB.keys.relayKX)
        let markB = try await rig.send(rig.b, "wt-canary-rot3s-")
        try await rig.settle(rig.b, "the static phone's echo in epoch \(e3)")
        XCTAssertEqual(try rig.phoneA.undelivered().count, 0)
        report = RotReport(rig: rig, epoch: e3, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey)
        report.heldMark = heldMark
        report.heldSeq = heldRow.actionSeq
        report.freeMarks = [markB]
        report.prevKX = fetchA.keys.previousRelayKX != nil
        try await rig.checkKeyboxLogs()
        _ = try await rig.report("r3", report, into: "r3.ok")
    }

    // MARK: Step 4: three rotations away, then an echo in a gone epoch

    /// Three rotations with the offering phone away and an action held in its outbox, sealed in the epoch it left
    /// (which the hub erases meanwhile). Back: the hub answers `resend_from`, the keybox merge reseals the row under
    /// the same `action_seq`, and it is applied once; the feed is not jammed. Then the echo of an action is left unread
    /// while the phone moves two epochs on: it is dropped as `epochKeysGone`, the action goes again, overwrites the
    /// hub's record and is answered as a repeat.
    private func stepLongAway(_ handoff: Handoff, _ rig: inout RotationRig) async throws {
        handoff.step = "r4"
        let e3 = try rig.phoneA.newestEpoch()
        let offer = try XCTUnwrap(try rig.linkA().offeredKX)
        let held = try await rig.heldOutbox(ahead: 3 * Self.rotationJump)
        let heldMark = "wt-canary-rot4-" + UUID().uuidString.lowercased()
        try await held.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(heldMark)])
        let heldRow = try XCTUnwrap(try rig.phoneA.replica.outboxRows([.queued]).last)
        XCTAssertEqual(heldRow.epoch, e3)
        var report = RotReport(rig: rig, epoch: e3, offer: offer.publicKey)
        report.heldMark = heldMark
        report.heldSeq = heldRow.actionSeq
        let answer = try await rig.report("r4.ready", report, into: "r4.go")
        rig.clock.set(answer.offset)

        // Back: the held action goes out sealed in e3, which the hub erased; its answer is sealed in an epoch the
        // phone has no keybox for yet, so the feed waits for it.
        handoff.step = "r4_resend_from"
        await held.releaseFlushes()
        _ = try await held.flush()
        try await rig.a.pollUntil(within: Self.stepWait, "the hub's answer in an epoch still to come") { _ in
            try rig.phoneA.replica.relayWaitSince() != nil
        }
        let fetchA = try await rig.a.fetchKeybox(atLeast: e3 + 3)
        let e6 = fetchA.keys.epoch
        XCTAssertEqual(e6, e3 + 3)
        XCTAssertEqual(fetchA.keys.relayKX.flatMap { WireBytes.fromBase64URL($0.devicePub) }, offer.publicKey)
        try checkPrevious(fetchA)
        // The merge resealed the row; its echo has not been read yet (an `applied` echo deletes the row).
        let resealed = try XCTUnwrap(
            try rig.phoneA.replica.outboxRows([.queued, .sent]).first { $0.actionID == heldRow.actionID },
            "the held action is still waiting for its echo")
        XCTAssertEqual(resealed.actionSeq, heldRow.actionSeq, "resealed under the same action_seq")
        XCTAssertEqual(resealed.epoch, e6, "resealed in the new epoch")
        XCTAssertNotEqual(resealed.envelope, heldRow.envelope, "a new envelope")
        try await rig.settle(rig.a, "the held action's echo")
        XCTAssertNil(try rig.phoneA.replica.outboxRows([.queued, .sent, .settled]).first { $0.actionID == heldRow.actionID },
                     "the applied echo removed the row")
        XCTAssertEqual(try rig.phoneA.undelivered().count, 0)
        // Not jammed: a fresh action goes through.
        let after = try await rig.send(rig.a, "wt-canary-rot4b-")
        try await rig.settle(rig.a, "a fresh action after the return")

        // The echo left unread in e6.
        handoff.step = "r4_gone"
        let goneMark = try await rig.send(rig.a, "wt-canary-rot4z-")
        let goneRow = try XCTUnwrap(try rig.phoneA.replica.outboxRows([.queued, .sent]).last)
        report = RotReport(rig: rig, epoch: e6, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey)
        report.heldMark = heldMark
        report.heldSeq = heldRow.actionSeq
        report.marks = [after]
        report.goneMark = goneMark
        report.goneSeq = goneRow.actionSeq
        report.prevKX = fetchA.keys.previousRelayKX != nil
        var next = try await rig.report("r4", report, into: "r5.go")
        rig.clock.set(next.offset)
        let fetch7 = try await rig.a.fetchKeybox(atLeast: e6 + 1)
        try checkPrevious(fetch7)
        next = try await rig.report(
            "r5.ready", RotReport(rig: rig, epoch: fetch7.keys.epoch, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey),
            into: "r6.go")
        rig.clock.set(next.offset)
        let fetch8 = try await rig.a.fetchKeybox(atLeast: e6 + 2)
        try checkPrevious(fetch8)
        XCTAssertFalse(try rig.linkA().epochs.contains { $0.epoch == e6 }, "epoch \(e6) is gone from the link")
        handoff.step = "r6_repeat"
        // The fetched merges moved the unechoed row out of the gone epoch and sent it again, same action_seq.
        let resent = try XCTUnwrap(try rig.phoneA.replica.outboxRows([.queued, .sent]).first { $0.actionID == goneRow.actionID },
                                   "the action whose echo is in the gone epoch still waits")
        XCTAssertEqual(resent.actionSeq, goneRow.actionSeq)
        XCTAssertEqual(resent.epoch, fetch8.keys.epoch)
        try await rig.settle(rig.a, "the resent action's repeat echo")
        XCTAssertEqual(try rig.phoneA.undelivered().count, 0, "nothing listed: the repeat settled it")
        report = RotReport(rig: rig, epoch: fetch8.keys.epoch, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey)
        report.goneMark = goneMark
        report.goneSeq = goneRow.actionSeq
        try await rig.checkKeyboxLogs()
        _ = try await rig.report("r6", report, into: "r6.ok")
    }

    // MARK: Step 5: to iCloud with an offer out, back after the anti-flap

    /// The offering phone asks for iCloud while its offer is out: the new epoch is static, the offer is cleared on
    /// the phone (the hub's side is checked by Go) and an action is applied over iCloud. Back to the relay once the
    /// hub's clock is past the 5-minute rule: the switch's epoch is static, the ack carries a fresh offer, and the
    /// next rotation is ephemeral.
    private func stepICloudAndBack(_ handoff: Handoff, _ rig: inout RotationRig) async throws {
        handoff.step = "s5_icloud"
        let before = try rig.phoneA.newestEpoch()
        XCTAssertNotNil(try rig.linkA().offeredKX, "an offer is out when the phone asks for iCloud")
        let toICloud = UUID().uuidString
        _ = try await rig.a.outbox.enqueueSwitchRequest(target: .cloudKit, id: toICloud)
        _ = try await rig.a.outbox.flush()
        try await rig.a.writeRequestCopy(target: .cloudKit, id: toICloud, on: .cloudKit)
        for follower in [rig.a, rig.b] {
            try await follower.pollUntil(within: Self.stepWait, "the move to iCloud") { await $0.route == .cloudKit }
            _ = try await follower.drainLeft()
        }
        let onICloud = try rig.phoneA.newestEpoch()
        XCTAssertEqual(onICloud, before + 1)
        XCTAssertEqual(try rig.phoneB.newestEpoch(), onICloud)
        let logA = await rig.a.keyboxLog
        XCTAssertEqual(logA.keyed[onICloud], false, "the switch to iCloud is static")
        // The offer and the current key go; the stored pairs stay for the late echoes of the epochs they key.
        XCTAssertNil(try rig.linkA().offeredKX, "the offer is cleared on the phone")
        XCTAssertNil(try rig.linkA().currentKX, "the current ephemeral key is cleared on the phone")
        let icloudMark = try await rig.send(rig.a, "wt-canary-rot5i-")
        try await rig.settle(rig.a, "an action over iCloud")
        var report = RotReport(rig: rig, epoch: onICloud, offer: nil)
        report.marks = [icloudMark]
        let answer = try await rig.report("s5.icloud", report, into: "s5.icloud.ok")
        rig.clock.set(answer.offset)

        handoff.step = "s5_relay"
        let toRelay = UUID().uuidString
        _ = try await rig.a.outbox.enqueueSwitchRequest(target: .relay, id: toRelay)
        _ = try await rig.a.outbox.flush()
        try await rig.a.writeRequestCopy(target: .relay, id: toRelay, on: .relay)
        for follower in [rig.a, rig.b] {
            try await follower.pollUntil(within: Self.stepWait, "the move back to the relay") { await $0.route == .relay }
            _ = try await follower.drainLeft()
        }
        let back = try rig.phoneA.newestEpoch()
        XCTAssertEqual(back, onICloud + 1)
        let logBack = await rig.a.keyboxLog
        XCTAssertEqual(logBack.keyed[back], false, "the switch back to the relay is static")
        let offer = try XCTUnwrap(try rig.linkA().offeredKX, "the ack of the switch back carries a fresh offer")
        let next = try await rig.report("s5.relay", RotReport(rig: rig, epoch: back, offer: offer.publicKey), into: "s5.go")
        rig.clock.set(next.offset)

        handoff.step = "s5_rotate"
        let fetchA = try await rig.a.fetchKeybox(atLeast: back + 1)
        XCTAssertEqual(fetchA.keys.epoch, back + 1)
        XCTAssertEqual(fetchA.keys.relayKX.flatMap { WireBytes.fromBase64URL($0.devicePub) }, offer.publicKey,
                       "ephemeral again one rotation after the return")
        try checkPromoted(fetchA, offer: offer, oldCurrent: nil)
        try checkPrevious(fetchA)
        let fetchB = try await rig.b.fetchKeybox(atLeast: back + 1)
        XCTAssertNil(fetchB.keys.relayKX)
        let mark = try await rig.send(rig.a, "wt-canary-rot5r-")
        try await rig.settle(rig.a, "an action after the return")
        report = RotReport(rig: rig, epoch: fetchA.keys.epoch, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey)
        report.marks = [mark]
        report.prevKX = fetchA.keys.previousRelayKX != nil
        try await rig.checkKeyboxLogs()
        _ = try await rig.report("s5", report, into: "s5.ok")
    }

    // MARK: Step 8: one of two paying phones lapses, then pays again

    /// The offering phone's entitlement expires on the stand while the static phone still pays: the hub stays on the
    /// relay, clears the lapsed phone's offer and rows (checked by Go) and tells it `hub_on_relay`; the phone drops
    /// every ephemeral key and leaves for iCloud, and the static phone goes on rotating. 15 moved days later it pays
    /// again: the keybox read at the reader wait is merged, its request for the relay is answered and followed, the ack
    /// carries a new offer and the next rotation is ephemeral.
    private func stepLapse(_ handoff: Handoff, _ rig: inout RotationRig) async throws {
        handoff.step = "s8_lapse"
        let account = try await stand.accountID(ofPhone: rig.relayIDs.a)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
        try await rig.a.pollUntil(within: Self.goWait, "hub_on_relay after the lapse") { await $0.route == .cloudKit }
        XCTAssertFalse(try rig.linkA().hasEphemeralState, "an opened hub_on_relay dropped every ephemeral key")
        let routeB = await rig.b.route
        XCTAssertEqual(routeB, .relay, "the paying phone stays on the relay")
        let left = try await rig.report("s8.left", RotReport(rig: rig, epoch: try rig.phoneA.newestEpoch(), offer: nil), into: "s8.go")
        rig.clock.set(left.offset)
        let fetchB = try await rig.b.fetchKeybox(atLeast: try XCTUnwrap(left.epoch))
        XCTAssertNil(fetchB.keys.relayKX)
        let markB = try await rig.send(rig.b, "wt-canary-rot8s-")
        try await rig.settle(rig.b, "the paying phone's echo after the other's lapse")
        var report = RotReport(rig: rig, epoch: fetchB.keys.epoch, offer: nil)
        report.freeMarks = [markB]
        let later = try await rig.report("s8", report, into: "s8.ok")
        rig.clock.set(later.offset)

        handoff.step = "s8_pays_again"
        try await stand.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
        try await poll(within: Self.goWait, "the reader wait") {
            do {
                try await rig.relayA.pull(only: [.data])
                return true
            } catch HostedRelayError.server(code: .forbidden, _) {
                return false
            } catch HostedRelayError.server(code: .entitlementInactive, _) {
                return false
            }
        }
        let merged = try await rig.a.mergeRelayKeybox(atLeast: try XCTUnwrap(later.epoch))
        XCTAssertNil(merged.relayKX, "the keybox at the reader wait is static: no offer was out")
        let again = UUID().uuidString
        _ = try await rig.a.outbox.enqueueSwitchRequest(target: .relay, id: again)
        _ = try await rig.a.outbox.flush()
        try await rig.a.writeRequestCopy(target: .relay, id: again, on: .relay)
        try await rig.a.pollUntil(within: Self.stepWait, "the request answered and followed") { await $0.route == .relay }
        _ = try await rig.a.drainLeft()
        let offer = try XCTUnwrap(try rig.linkA().offeredKX, "the ack on the relay carries a new offer")
        let rotated = try await rig.report(
            "s8.back", RotReport(rig: rig, epoch: try rig.phoneA.newestEpoch(), offer: offer.publicKey), into: "s8.rot")
        rig.clock.set(rotated.offset)
        let fetchA = try await rig.a.fetchKeybox(atLeast: try XCTUnwrap(rotated.epoch))
        XCTAssertEqual(fetchA.keys.relayKX.flatMap { WireBytes.fromBase64URL($0.devicePub) }, offer.publicKey,
                       "ephemeral at the next rotation")
        try checkPromoted(fetchA, offer: offer, oldCurrent: nil)
        try checkPrevious(fetchA)
        _ = try await rig.b.fetchKeybox(atLeast: fetchA.keys.epoch)
        let markA = try await rig.send(rig.a, "wt-canary-rot8b-")
        try await rig.settle(rig.a, "an action after paying again")
        report = RotReport(rig: rig, epoch: fetchA.keys.epoch, offer: try XCTUnwrap(try rig.linkA().offeredKX).publicKey)
        report.marks = [markA]
        report.prevKX = fetchA.keys.previousRelayKX != nil
        try await rig.checkKeyboxLogs()
        _ = try await rig.report("s8.done", report, into: "s8.done.ok")
    }

    // MARK: Step 7: the real relay's answers to a phone without a slot

    /// A third paying phone, never linked to the hub (the stand makes one: a relay account the hub never saw), at the
    /// transport level (the app's slot handling is the phone wiring tests' of Tasks 13 and 17). With no slot for the
    /// Mac: a save into its mailbox with the Mac and a read of `data/<mac>` are `FORBIDDEN`. With the slot and the
    /// entitlement expired on the stand: a save is `ENTITLEMENT_INACTIVE`. Paying again, slot removed: the record it
    /// wrote while slotted is deleted with no slot, and save and read are `FORBIDDEN` again.
    private func stepRelayAnswers(_ handoff: Handoff, _ rig: RotationRig) async throws {
        handoff.step = "s7_relay_answers"
        let client = try await makeClient(kind: .phone, seed: 3)
        try await pay(client)
        let mailbox = HostedRelayZones.mailbox(mac: rig.mac, phone: client.deviceID)
        let data = HostedRelayZones.data(mac: rig.mac)
        let own = "wt-own-" + UUID().uuidString.lowercased()

        let unslottedSave = await Self.relayCode { try await Self.saveOne(client, mailbox, own) }
        XCTAssertEqual(unslottedSave, .forbidden, "a save into the Mac's mailbox with no slot")
        let unslottedRead = await Self.relayCode { try await Self.read(client, data) }
        XCTAssertEqual(unslottedRead, .forbidden, "a read of data/<mac> with no slot")

        let pairing = HostedRelayPairing(session: HostedRelaySession(client: client))
        try await pairing.vouch(hubDeviceID: rig.mac, authPub: rig.hubAuth)
        try await pairing.addSlot(mac: rig.mac)
        let seq = try await Self.saveOne(client, mailbox, own)
        let account = try await stand.accountID(ofPhone: client.deviceID)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
        let lapsedSave = await Self.relayCode { try await Self.saveOne(client, mailbox, own + "-lapsed") }
        XCTAssertEqual(lapsedSave, .entitlementInactive, "a save by a slotted phone that does not pay")

        try await stand.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
        try await pairing.removeSlot(mac: rig.mac)
        let removedSave = await Self.relayCode { try await Self.saveOne(client, mailbox, own + "-after") }
        XCTAssertEqual(removedSave, .forbidden, "a save after the slot is removed")
        let removedRead = await Self.relayCode { try await Self.read(client, data) }
        XCTAssertEqual(removedRead, .forbidden, "a read of data/<mac> after the slot is removed")
        var delete = Relay_V1_Delete()
        delete.zone = mailbox
        var item = Relay_V1_DeleteItem()
        item.name = own
        item.expectedSeq = seq
        delete.items = [item]
        let deleted = await Self.relayCode {
            let result = try await client.delete(delete)
            XCTAssertTrue(result.conflicts.isEmpty, "its own record, at the seq it wrote")
        }
        XCTAssertNil(deleted, "a phone with no slot deletes its own record")
        KitFollower.trace("""
            relay answers: unslotted save \(String(describing: unslottedSave)), read \(String(describing: unslottedRead)); \
            lapsed save \(String(describing: lapsedSave)); removed save \(String(describing: removedSave)), \
            read \(String(describing: removedRead)); own delete \(deleted.map { String(describing: $0) } ?? "ok")
            """)
    }

    /// The relay's error code for `body`, nil when it succeeded; any other error fails the test.
    private static func relayCode(_ body: () async throws -> Void) async -> Relay_V1_ErrorCode? {
        do {
            try await body()
            return nil
        } catch HostedRelayError.server(let code, _) {
            return code
        } catch {
            XCTFail("not a relay answer: \(error)")
            return nil
        }
    }

    /// Saves one record (its name as the envelope, must not exist) and returns its seq.
    private static func saveOne(_ client: HostedRelayClient, _ zone: String, _ name: String) async throws -> UInt64 {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = name
        item.record.envelope = Data(name.utf8)
        item.mustNotExist = true
        var save = Relay_V1_Save()
        save.items = [item]
        let result = try await client.save(save)
        return try XCTUnwrap(result.saved.first, "saved, no conflict").recordSeq
    }

    private static func read(_ client: HostedRelayClient, _ zone: String) async throws {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        _ = try await client.changes(changes)
    }

    // MARK: Checks

    /// The keybox opened with the offer, the pair derived and stored, the offer promoted; the private key of the
    /// current key it replaced is gone from the encoded item.
    private func checkPromoted(_ fetch: KeyboxFetch, offer: EphemeralKey, oldCurrent: EphemeralKey?) throws {
        let after = fetch.after
        XCTAssertEqual(after.currentKX?.publicKey, offer.publicKey, "the offer is promoted to the current key")
        XCTAssertNil(after.offeredKX, "no offer outstanding right after the promotion")
        let pair = try XCTUnwrap(after.epochs.first { $0.epoch == fetch.keys.epoch }?.relayKeys, "the epoch's pair is stored")
        XCTAssertEqual(pair.devicePub, offer.publicKey)
        guard let oldCurrent else { return }
        let encoded = try JSONEncoder().encode(after)
        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(oldCurrent.privateKey.base64EncodedString()), "the old private key is gone from the item")
        let decoded = try JSONDecoder().decode(HubLinkKeys.self, from: encoded)
        XCTAssertNotEqual(decoded.currentKX?.privateKey, oldCurrent.privateKey)
        XCTAssertNotEqual(decoded.offeredKX?.privateKey, oldCurrent.privateKey)
    }

    /// The hub sends `previous_relay_kx` while it holds that row: whenever the phone holds a pair for the keybox's
    /// previous epoch (so the hub keyed it), the keybox names that very pair.
    private func checkPrevious(_ fetch: KeyboxFetch) throws {
        guard let previous = fetch.keys.previousEpoch,
              let held = fetch.before.epochs.first(where: { $0.epoch == previous })?.relayKeys else { return }
        let kx = try XCTUnwrap(fetch.keys.previousRelayKX, "epoch \(previous) is keyed for this phone: previous_relay_kx is sent")
        XCTAssertEqual(WireBytes.fromBase64URL(kx.devicePub), held.devicePub)
        XCTAssertEqual(WireBytes.fromBase64URL(kx.hubPub), held.hubPub)
    }
}

// MARK: - The rig

/// The hub's clock as the phones read it: the real time plus the offset the Go side moved it by.
final class HubClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    var now: Date {
        Date().addingTimeInterval(lock.withLock { $0 })
    }

    var closure: @Sendable () -> Date {
        { [self] in now }
    }

    func set(_ offset: TimeInterval) {
        lock.withLock { $0 = offset }
    }
}

/// A follower's keys in the rotation run: every merge is the app's, on `clock`; `offers` acks the relay route's
/// epochs with an offer.
struct FollowerKeys: Sendable {
    let offers: Bool
    let clock: HubClock
}

/// Every keybox a phone merged: whether each epoch was keyed (`relay_kx`). The hub must never send one phone a static
/// keybox and then a keyed one for the same epoch (the phone refuses that order); `staticThenKeyed` lists any.
struct KeyboxLog: Sendable {
    private(set) var keyed: [UInt32: Bool] = [:]
    private(set) var staticThenKeyed: [UInt32] = []

    mutating func saw(_ keys: KeyboxKeys) {
        note(keys.epoch, keyed: keys.relayKX != nil)
        if let previous = keys.previousEpoch {
            note(previous, keyed: keys.previousRelayKX != nil)
        }
    }

    private mutating func note(_ epoch: UInt32, keyed now: Bool) {
        if keyed[epoch] == false, now { staticThenKeyed.append(epoch) }
        keyed[epoch] = (keyed[epoch] ?? false) || now
    }
}

/// A fetched keybox: its keys, and the link right before and right after the merge.
struct KeyboxFetch {
    let keys: KeyboxKeys
    let before: HubLinkKeys
    let after: HubLinkKeys
}

/// The two phones of the rotation run.
struct RotationRig {
    let a: KitFollower
    let b: KitFollower
    let phoneA: ICloudPhone
    let phoneB: ICloudPhone
    let relayA: HostedRelayTransport
    let mac: String
    /// The hub's relay auth key from the grant, for a vouch.
    let hubAuth: Data
    let clock: HubClock
    let relayIDs: (a: String, b: String)

    var handoff: Handoff {
        Handoff(dir: URL(fileURLWithPath: ProcessInfo.processInfo.environment[KitGoHubInteropTests.handoffVariable] ?? ""))
    }

    func linkA() throws -> HubLinkKeys {
        try XCTUnwrap(try phoneA.link.keys.hubLink(phoneA.link.hubID))
    }

    func linkB() throws -> HubLinkKeys {
        try XCTUnwrap(try phoneB.link.keys.hubLink(phoneB.link.hubID))
    }

    /// Writes `name` with `report` and waits for the hub's `answer`.
    func report(_ name: String, _ report: RotReport, into answer: String) async throws -> RotAnswer {
        handoff.write(name, String(bytes: try JSONEncoder().encode(report), encoding: .utf8) ?? "")
        let text = try await handoff.wait(answer, KitGoHubInteropTests.goWait)
        return try JSONDecoder().decode(RotAnswer.self, from: Data(text.utf8))
    }

    /// An outbox for the offering phone on its relay route, held, stamping the hub's clock `ahead` on: an action it
    /// queues is sealed now and sent later.
    func heldOutbox(ahead: TimeInterval) async throws -> ActionOutbox {
        let clock = clock
        let outbox = ActionOutbox(
            transport: phoneA.secure(relayA), store: phoneA.replica, deviceID: phoneA.link.deviceID.uuidString,
            route: .hostedRelay(macDeviceID: mac)
        ) { clock.now.addingTimeInterval(ahead) }
        await outbox.setHubID(phoneA.code.hubID)
        await outbox.holdFlushes()
        return outbox
    }

    /// One marked action through the follower's outbox, flushed; returns its mark.
    func send(_ follower: KitFollower, _ prefix: String) async throws -> String {
        let mark = prefix + UUID().uuidString.lowercased()
        let outbox = await follower.outbox
        try await outbox.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(mark)])
        _ = try await outbox.flush()
        return mark
    }

    /// Feed cycles until the follower's phone has no action waiting for its echo.
    func settle(_ follower: KitFollower, _ what: String) async throws {
        let phone = follower === a ? phoneA : phoneB
        try await follower.pollUntil(within: KitGoHubInteropTests.stepWait, what) { _ in
            try phone.replica.outboxRows([.queued, .sent]).isEmpty
        }
    }

    /// Neither phone saw a static keybox and then a keyed one for the same epoch.
    func checkKeyboxLogs() async throws {
        for follower in [a, b] {
            let log = await follower.keyboxLog
            XCTAssertEqual(log.staticThenKeyed, [], "a static keybox, then a keyed one, for the same epoch")
        }
    }
}

/// What the phone writes with each step (`rotReport` on the Go side).
struct RotReport: Encodable {
    var relayA: String
    var relayB: String
    var offer: String
    var epoch: UInt32
    var marks: [String] = []
    var freeMarks: [String] = []
    var heldMark = ""
    var heldSeq: UInt64 = 0
    var goneMark = ""
    var goneSeq: UInt64 = 0
    var prevKX = false

    init(rig: RotationRig, epoch: UInt32, offer: Data?) {
        relayA = rig.relayIDs.a
        relayB = rig.relayIDs.b
        self.offer = offer.map(WireBytes.base64URL) ?? ""
        self.epoch = epoch
    }

    enum CodingKeys: String, CodingKey {
        case relayA = "relay_a", relayB = "relay_b", offer, epoch, marks, freeMarks = "free_marks"
        case heldMark = "held_mark", heldSeq = "held_seq", goneMark = "gone_mark", goneSeq = "gone_seq", prevKX = "prev_kx"
    }
}

/// The hub's answer (`rotAnswer` on the Go side): its clock's offset in seconds, and the alert push it sent the
/// offering phone (base64url), when the step made one.
struct RotAnswer: Decodable {
    let offsetS: Int64
    let push: String?
    /// The hub's current epoch, when the step names it.
    let epoch: UInt32?

    var offset: TimeInterval {
        TimeInterval(offsetS)
    }

    enum CodingKeys: String, CodingKey {
        case offsetS = "offset_s", push, epoch
    }
}
