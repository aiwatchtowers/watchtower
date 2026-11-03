import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
@testable import WatchtowerSync
import XCTest

/// The transport switch both ways (relay client Phase 3b Task 20), run by
/// `make relay-interop-kit-hub RELAY=<relay checkout> RELAY_INTEROP_DESKTOP=1` beside the Go side's
/// `TestInterop_KitPhoneFollowsASwitch` (`internal/hub/interop_kit_test.go` lists the handoff files). The Go hub is a
/// Mac's desktop host: its CloudKit side reaches the phone through the loopback store (`LoopbackCloudTransport`, R24),
/// its relay side through the stand. Two Kit phones link over iCloud; the first upgrades with the calls
/// `RelayUpgrader` makes (device record with the proven relay id, `vouch`, `add_slot`, the first data-zone read,
/// `transport_switch(relay)` in both mailboxes) and follows every switch through `TransportFollowerPolicy`, as the app's
/// `TransportFollower` executes it; the second never upgrades.
extension KitGoHubInteropTests {
    /// How far the Go side moves the hub's clock after the too-soon check (`clock.jump` in the Go test).
    static let hubClockJump: TimeInterval = 8 * 86_400

    func testKitPhoneFollowsBothWays() async throws {
        guard ProcessInfo.processInfo.environment[Self.desktopVariable] == "1" else {
            throw XCTSkip("\(Self.desktopVariable) is not 1: the switch runs only in the desktop host's run")
        }
        let handoff = Handoff(dir: try handoffDir())
        do {
            try await followBothWays(handoff)
        } catch {
            handoff.write("kit.fail", handoff.step)
            throw error
        }
    }

    // swiftlint:disable:next function_body_length
    private func followBothWays(_ handoff: Handoff) async throws {
        handoff.step = "ck_url"
        _ = try await handoff.wait(LoopbackCloudEndpoint.handoffFile, Self.goWait)
        let endpoint = try LoopbackCloudEndpoint.read(fromHandoff: handoff.dir)

        // 1. Both phones link over iCloud (private scope: the Mac's own Apple ID).
        handoff.step = "link"
        let phone = try await ICloudPhone.link(handoff, endpoint: endpoint, files: ("pair.url", "pair.sas", "confirmed"))
        handoff.step = "link_free"
        let free = try await ICloudPhone.link(handoff, endpoint: endpoint, files: ("free.url", "free.sas", "free.confirmed"))
        let linkedEpoch = try phone.newestEpoch()

        // 2. The upgrade, steps 1–5 of `RelayUpgrader`.
        handoff.step = "upgrade"
        let grant = try await phone.keybox(over: phone.cloud) { $0.grant.linked }.grant
        XCTAssertTrue(grant.runsOrderedActions)
        let mac = try XCTUnwrap(grant.relayDeviceID)
        let hubAuth = try XCTUnwrap(grant.relayAuthPub.flatMap(WireBytes.fromBase64URL))
        let client = try await makeClient(kind: .phone, seed: 1)
        try await pay(client)
        let signer = try backend.signer(seed: 1)
        let proof = try RelayIDProof.sign(authPub: signer.publicKey, hubID: phone.link.hubUUID, deviceID: phone.link.deviceID) {
            try signer.sign($0)
        }
        XCTAssertEqual(proof.relayDeviceID, client.deviceID)
        let follower = try await KitFollower(phone: phone, canUseRelay: .yes)
        // Three actions with canaries go out on iCloud before the switch; their echoes are not read there.
        let marks = (1...3).map { _ in "wt-canary-kit-" + UUID().uuidString.lowercased() }
        for mark in marks {
            try await follower.outbox.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(mark)])
        }
        _ = try await follower.outbox.flush()
        // Step 1: the device record with the proven relay id.
        try await phone.saveRetrying([try CloudRecordFactory.record(
            for: phone.link.device(nonce: nil, unlinked: false, relay: proof), modifiedAt: Date())])
        // Steps 2–3: vouch, add_slot.
        let session = HostedRelaySession(client: client)
        let pairing = HostedRelayPairing(session: session)
        try await pairing.vouch(hubDeviceID: mac, authPub: hubAuth)
        try await pairing.addSlot(mac: mac)
        // Step 3a: the first data-zone read (FORBIDDEN until the hub names the phone a reader).
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
        // Step 4: the request in the iCloud mailbox through the outbox, its copy in the relay mailbox, one id.
        let requestID = UUID().uuidString
        _ = try await follower.outbox.enqueueSwitchRequest(target: .relay, id: requestID)
        _ = try await follower.outbox.flush()
        try await follower.writeRequestCopy(target: .relay, id: requestID, on: .relay)
        // The free phone names the paying phone's relay id with its own key.
        let freeSigner = try backend.signer(seed: 2)
        let forged = try freeSigner.sign(RelayIDProof.message(
            hubID: free.link.hubUUID, deviceID: free.link.deviceID, relayDeviceID: client.deviceID))
        try await free.saveRetrying([try CloudRecordFactory.record(
            for: free.link.device(nonce: nil, unlinked: false, relay: (
                client.deviceID, WireBytes.base64URL(freeSigner.publicKey), WireBytes.base64URL(forged))),
            modifiedAt: Date())])
        var report = SwitchReport(relayDeviceID: client.deviceID, marks: marks)
        try await handoff.report("upgraded", report, Self.goWait)

        // 3. On the relay: the phone follows `transport_switched` (read on iCloud), resends its unechoed actions with
        // the same bytes, acknowledges the new epoch and drains its iCloud mailbox.
        handoff.step = "follow_relay"
        let unechoed = try phone.replica.outboxRows([.queued, .sent])
        XCTAssertEqual(unechoed.map(\.actionSeq).count, 3, "the three actions wait for their echoes")
        // Controls only: the iCloud echoes of the three stay unread, so they are unechoed when the phone moves (a phone
        // that had not read them yet) and rule 13 resends them.
        try await poll(within: Self.stepWait, "the move to the relay") {
            try await follower.readRouteControls()
            return await follower.route == .relay
        }
        XCTAssertEqual(try phone.newestEpoch(), linkedEpoch + 1)
        // The rows the move queued again, read right after `resendUnechoed` (their echoes may settle them at once).
        let resent = await follower.lastResent.filter { row in unechoed.contains { $0.actionID == row.actionID } }
        XCTAssertEqual(resent.count, 3, "the three unechoed actions were queued again on the relay")
        for row in resent {
            XCTAssertEqual(row.envelope, unechoed.first { $0.actionID == row.actionID }?.envelope, "resent with the same bytes")
        }
        try await follower.pollUntil(within: Self.stepWait, "the echoes of the resent actions") { _ in
            try phone.replica.outboxRows([.queued, .sent]).isEmpty
        }
        let drainedCloud = try await follower.drainLeft()
        XCTAssertEqual(drainedCloud, .drained)
        let cloudLeft = try await phone.secureCloud.relayHygieneScan().opened
        XCTAssertTrue(
            cloudLeft.allSatisfy { $0.kind == RelayRecordKind.device.rawValue },
            "the iCloud mailbox holds \(cloudLeft.map(\.kind))")
        // An ask alert raised while the hub runs on the relay (the mark's handler raises it).
        let alertMark = "wt-canary-alert-" + UUID().uuidString.lowercased()
        try await follower.outbox.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(alertMark)])
        try await follower.pollUntil(within: Self.stepWait, "the alert mark's echo") { _ in
            try phone.replica.outboxRows([.queued, .sent]).isEmpty
        }
        // The free phone: two actions on iCloud, then `hub_on_relay`, both Not delivered.
        handoff.step = "free_phone"
        let freeFollower = try await KitFollower(phone: free, canUseRelay: .no)
        let freeMarks = (1...2).map { _ in "wt-canary-free-" + UUID().uuidString.lowercased() }
        for mark in freeMarks {
            try await freeFollower.outbox.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(mark)])
        }
        _ = try await freeFollower.outbox.flush()
        try await freeFollower.pollUntil(within: Self.stepWait, "hub_on_relay on iCloud") { _ in
            try free.undelivered().count == 2
        }
        for row in try free.undelivered() {
            XCTAssertEqual(row.errorMessage, ActionOutbox.hubOnRelayMessage)
        }
        let freeRoute = await freeFollower.route
        XCTAssertEqual(freeRoute, .cloudKit)
        report.freeMarks = freeMarks
        report.alertMark = alertMark
        report.epoch = try phone.newestEpoch()
        try await handoff.report("on.relay", report, Self.goWait)

        // 4–5. Back to iCloud at once. The action that will be sealed in a retired epoch is queued first, held; the
        // request is written straight into both mailboxes (the outbox is held). The hub's relay copy of the notice is
        // deleted before the phone reads it: the phone follows the marker in the relay data zone and reads its keybox
        // from the iCloud data zone.
        handoff.step = "back_icloud"
        await follower.outbox.holdFlushes()
        // Made "on the last day" (as Go's TestAPhoneOfflineOver7DaysAcrossASwitchRecovers): its created_at is the
        // hub's clock after the 8-day move, so the action is not past its age when it arrives; it is sealed now, in
        // the relay epoch. A second outbox on the same replica and transport, held too, so only the session on iCloud
        // writes it.
        let later = ActionOutbox(
            transport: phone.secure(relayT), store: phone.replica, deviceID: phone.link.deviceID.uuidString,
            route: .hostedRelay(macDeviceID: mac)
        ) { Date().addingTimeInterval(Self.hubClockJump) }
        await later.setHubID(phone.code.hubID)
        await later.holdFlushes()
        let oldMark = "wt-canary-old-" + UUID().uuidString.lowercased()
        try await later.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(oldMark)])
        let oldRow = try XCTUnwrap(try phone.replica.outboxRows([.queued]).last)
        XCTAssertEqual(oldRow.epoch, linkedEpoch + 1)
        await follower.holdNextOutbox()
        let backID = UUID().uuidString
        try await follower.writeRequestCopy(target: .cloudKit, id: backID, on: .cloudKit)
        try await follower.writeRequestCopy(target: .cloudKit, id: backID, on: .relay)
        try await poll(within: Self.stepWait, "the marker naming iCloud") {
            try await follower.followMarkerOnRelay()
            return await follower.route == .cloudKit
        }
        XCTAssertEqual(try phone.newestEpoch(), linkedEpoch + 2)
        let drainedRelay = try await follower.drainLeft()
        XCTAssertEqual(drainedRelay, .drained)
        try await relayT.pull(only: [.relay])
        let relayLeft = try await phone.secure(relayT).relayHygieneScan().opened
        XCTAssertTrue(relayLeft.isEmpty, "the relay mailbox holds \(relayLeft.map(\.kind))")
        // 9. The open alert is in the iCloud data zone, signalled once, and opens with AlertOpener.
        handoff.step = "alert"
        try await poll(within: Self.stepWait, "the alert and its signal on iCloud") {
            try await phone.openAlerts().opened.contains("ask-t20")
        }
        let signals = try await phone.openAlerts().signals
        XCTAssertEqual(signals, 1, "the alert's signal records on iCloud")
        report.epoch = try phone.newestEpoch()
        try await handoff.report("back.icloud", report, Self.goWait)

        // 6. Too soon: the relay again within the anti-flap.
        handoff.step = "too_soon"
        let soonID = UUID().uuidString
        try await follower.writeRequestCopy(target: .relay, id: soonID, on: .cloudKit)
        try await follower.pollUntil(within: Self.stepWait, "the rejection") { _ in await follower.rejection != nil }
        let rejected = await follower.rejection
        let rejection = try XCTUnwrap(rejected)
        XCTAssertEqual(rejection.reason, "too_soon")
        let retryAfter = try XCTUnwrap(rejection.retryAfterS)
        XCTAssertGreaterThan(retryAfter, 0)
        XCTAssertLessThanOrEqual(retryAfter, 300)
        let soonRoute = await follower.route
        XCTAssertEqual(soonRoute, .cloudKit)
        report.retryAfter = Int(retryAfter)
        try await handoff.report("too.soon", report, Self.goWait)
        // From here the phone's clock reads as the hub's does (8 days on): the outboxes made from now on stamp it.
        await follower.setClockOffset(Self.hubClockJump)

        // 7. The hub retired epoch e+1 (its clock moved 8 days): the held action, sealed in it, draws a `resend_from`,
        // is resealed under the same `action_seq` and applied once.
        handoff.step = "old_epoch"
        await follower.outbox.releaseFlushes()
        _ = try await follower.outbox.flush()
        try await follower.pollUntil(within: Self.stepWait, "the old action's echo") { _ in
            try phone.replica.outboxRows([.queued, .sent]).isEmpty
        }
        XCTAssertEqual(try phone.undelivered().count, 0, "the old action is not listed")
        XCTAssertFalse(try phone.replica.pendingActions().contains { $0.state == .failed }, "the old action did not fail")
        report.oldMark = oldMark
        report.oldSeq = oldRow.actionSeq
        report.epoch = try phone.newestEpoch()
        try await handoff.report("old.epoch", report, Self.goWait)

        // 8. The lapse: the relay again (the anti-flap is past on the hub's clock), then the entitlement expires.
        handoff.step = "relay_again"
        let againID = UUID().uuidString
        _ = try await follower.outbox.enqueueSwitchRequest(target: .relay, id: againID)
        _ = try await follower.outbox.flush()
        try await follower.writeRequestCopy(target: .relay, id: againID, on: .relay)
        try await follower.pollUntil(within: Self.stepWait, "the second move to the relay") { await $0.route == .relay }
        let drainedAgain = try await follower.drainLeft()
        XCTAssertEqual(drainedAgain, .drained)
        let lapseMarks = (1...2).map { _ in "wt-canary-lapse-" + UUID().uuidString.lowercased() }
        for mark in lapseMarks {
            try await follower.outbox.enqueue(kind: .digestRead, entityRecordName: nil, params: ["mark": .string(mark)])
        }
        _ = try await follower.outbox.flush()
        // The lapse moment: no feed cycle ran since the flush, so both are still without their echo.
        let atLapse = try phone.replica.outboxRows([.queued, .sent])
        XCTAssertEqual(atLapse.count, lapseMarks.count, "the lapse actions are unechoed when the entitlement expires")
        handoff.step = "lapse"
        let account = try await stand.accountID(ofPhone: client.deviceID)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
        try await follower.pollUntil(within: Self.goWait, "the fall back to iCloud") { await $0.route == .cloudKit }
        let switchedBy = await follower.switchedBy
        XCTAssertEqual(switchedBy, "entitlement_expired")
        _ = try await follower.drainLeft()
        try await follower.pollUntil(within: Self.stepWait, "every lapse action settled") { _ in
            try phone.replica.outboxRows([.queued, .sent]).isEmpty
        }
        // Nothing dropped silently: every row either got its echo or is listed with a reason.
        XCTAssertEqual(try phone.undelivered().count, 0)
        report.lapseMarks = lapseMarks
        report.epoch = try phone.newestEpoch()
        try await handoff.report("lapse.done", report, Self.goWait, answer: "go.ok")
        handoff.step = "done"
        await follower.stop()
        await freeFollower.stop()
    }
}

// MARK: - The report

/// What the phone writes with each step (`switchReport` on the Go side).
struct SwitchReport: Encodable {
    var relayDeviceID: String
    var marks: [String]
    var freeMarks: [String] = []
    var oldMark = ""
    var oldSeq: UInt64 = 0
    var lapseMarks: [String] = []
    var alertMark = ""
    var epoch: UInt32 = 0
    var retryAfter = 0

    enum CodingKeys: String, CodingKey {
        case relayDeviceID = "relay_device_id", marks, freeMarks = "free_marks", oldMark = "old_mark", oldSeq = "old_seq"
        case lapseMarks = "lapse_marks", alertMark = "alert_mark", epoch, retryAfter = "retry_after_s"
    }
}

extension Handoff {
    /// Writes `name` with `report`, then waits for the hub's answer (`<name>.ok` unless named).
    func report(_ name: String, _ report: SwitchReport, _ limit: TimeInterval, answer: String? = nil) async throws {
        write(name, String(bytes: try JSONEncoder().encode(report), encoding: .utf8) ?? "")
        _ = try await wait(answer ?? name + ".ok", limit)
    }
}

extension PhoneLink {
    func secure(on inner: any CloudSyncTransport & Sendable) -> SecureTransport {
        SecureTransport(inner: inner, keys: provider, rollback: replica)
    }

    /// The device record, with the relay id's three fields when given.
    func device(nonce: String?, unlinked: Bool, relay: (relayDeviceID: String, authPub: String, sig: String)?) -> DevicePayload {
        DevicePayload(
            deviceID: deviceID.uuidString, name: "Test Phone", model: "iPhone18,1", appVersion: "0.0.0-test", scope: .private,
            userRecordName: "", linkNonce: nonce, unlinked: unlinked ? true : nil, typingRequested: false, startSessions: true,
            updatedAt: Date(), relayDeviceID: relay?.relayDeviceID, relayAuthPub: relay?.authPub, relayIDSig: relay?.sig)
    }
}

// MARK: - A phone linked over iCloud

/// One Kit phone linked to the Go hub over the loopback CloudKit store.
final class ICloudPhone: @unchecked Sendable {
    let link: PhoneLink
    let cloud: LoopbackCloudTransport
    let secureCloud: SecureTransport
    let code: LinkPayload

    var replica: ReplicaStore { link.replica }

    private init(link: PhoneLink, cloud: LoopbackCloudTransport, code: LinkPayload) {
        self.link = link
        self.cloud = cloud
        self.code = code
        secureCloud = link.secure(on: cloud)
    }

    /// The link over iCloud: the hello in RelayZone (no relay id), the awaiting keybox, SAS v2, the owner's
    /// confirmation, the keys.
    static func link(
        _ handoff: Handoff, endpoint: LoopbackCloudEndpoint, files: (url: String, sas: String, confirmed: String)
    ) async throws -> ICloudPhone {
        let text = try await handoff.wait(files.url, KitGoHubInteropTests.goWait)
        guard let url = URL(string: text), case .success(let code) = LinkPayload.parse(url) else {
            throw GoHubInteropFailure.goFailed("\(files.url) is not a link code")
        }
        XCTAssertEqual(code.v, 4)
        let phone = ICloudPhone(link: try PhoneLink(code: code), cloud: LoopbackCloudTransport(endpoint: endpoint, user: nil), code: code)
        let hello = DeviceHello(
            device: phone.link.device(nonce: code.nonce, unlinked: false),
            signingKey: WireBytes.base64URL(phone.link.identity.signing.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(phone.link.identity.agreement.publicKey.rawRepresentation),
            relayDeviceID: nil)
        try await phone.saveRetrying([try CloudRecordFactory.record(for: hello, modifiedAt: Date())])
        let awaiting = try await phone.keybox(over: phone.cloud) { $0.grant.awaitingConfirmation == true && $0.grant.confirmNonce != nil }
        handoff.write(files.sas, try phone.link.sas(confirmNonce: try XCTUnwrap(awaiting.grant.confirmNonce)))
        _ = try await handoff.wait(files.confirmed, KitGoHubInteropTests.stepWait)
        let linked = try await phone.keybox(over: phone.cloud) { $0.grant.linked && $0.keys != nil }
        try phone.link.merge(try XCTUnwrap(linked.keys))
        return phone
    }

    /// Saves through the iCloud leg, again every second while the store answers unreachable (the bridge between
    /// two requests), as the app's CloudKit engine retries.
    func saveRetrying(_ records: [CloudRecord]) async throws {
        let deadline = Date().addingTimeInterval(KitGoHubInteropTests.stepWait)
        while true {
            do {
                return try await secureCloud.save(records)
            } catch {
                KitFollower.trace("iCloud save failed: \(error)")
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    func secure(_ relay: HostedRelayTransport) -> SecureTransport {
        link.secure(over: relay)
    }

    /// The newest epoch this phone holds.
    func newestEpoch() throws -> UInt32 {
        try XCTUnwrap(try link.keys.hubLink(link.hubID)?.epochs.map(\.epoch).max())
    }

    /// Reads `transport`'s data zone every second until this phone's keybox satisfies `wanted`.
    func keybox(
        over transport: any CloudSyncTransport,
        within limit: TimeInterval = KitGoHubInteropTests.stepWait,
        _ wanted: (Keybox) -> Bool
    ) async throws -> Keybox {
        let name = Keybox.recordName(deviceID: link.deviceID.uuidString)
        let deadline = Date().addingTimeInterval(limit)
        while true {
            if let relay = transport as? HostedRelayTransport { try await relay.pull(only: [.data]) }
            let batch = try await transport.changes(in: .data, since: nil)
            if let record = batch.changed.last(where: { $0.recordName == name }) {
                let box = try link.opener.openKeybox(wireName: record.recordName, envelope: record.payload)
                if wanted(box) { return box }
            }
            guard Date() < deadline else { throw GoHubInteropFailure.timedOut("keybox") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// The Not delivered list.
    func undelivered() throws -> [PendingAction] {
        try replica.reader.read { [replica] db in try replica.undeliveredActions(from: db) }
    }

    /// The ask alerts of the iCloud data zone that open with `AlertOpener` (their keys) and the signal records.
    func openAlerts() async throws -> (opened: Set<String>, signals: Int) {
        let link = try XCTUnwrap(try link.keys.hubLink(link.hubID))
        let opener = AlertOpener(material: AlertMaterial(epochs: link.epochs, hubSigningKey: link.hubSigningKey))
        let batch = try await cloud.changes(in: .data, since: nil)
        var opened: Set<String> = []
        var signals = 0
        for record in batch.changed {
            if record.recordName.hasPrefix("\(WireKind.signal)-") {
                signals += 1
            } else if let alert = opener.open(wireName: record.recordName, envelope: record.payload) {
                opened.insert(alert.key)
            }
        }
        return (opened, signals)
    }
}

// MARK: - The follower

/// Executes `TransportFollowerPolicy`'s commands for one Kit phone, in the app's `TransportFollower` order (the outbox
/// held and its unechoed actions queued again, the route moved, the keybox merged, the epoch acknowledged, the control
/// handled), with one outbox and one `RelayFeed` per route over the one replica (`ReplicaStore.adoptRoute`).
actor KitFollower {
    private let phone: ICloudPhone
    private let canUseRelay: RelayUse
    private(set) var route: TransportKind = .cloudKit
    private(set) var outbox: ActionOutbox
    private var feed: RelayFeed
    private var relay: (transport: HostedRelayTransport, mac: String)?
    private var left: TransportKind?
    private var holdNext = false
    private var clockOffset: TimeInterval = 0
    /// The rows the last move queued again (rule 13), read right after the requeue.
    private(set) var lastResent: [OutboxRow] = []
    /// The route the replica adopts before the next feed cycle (its tokens reset).
    private var adoptRoute: TransportKind?
    private(set) var switchedBy: String?
    /// The last `transport_switch_rejected` read.
    private(set) var rejection: ControlPayload?
    /// This phone's `transport_switch{relay}` waits for its answer (`FollowerState.relaySwitchRequested`, as the app's
    /// upgrade at `.requested`).
    private var relayRequested = false

    init(phone: ICloudPhone, canUseRelay: RelayUse) async throws {
        self.phone = phone
        self.canUseRelay = canUseRelay
        let outbox = try await Self.makeOutbox(phone, phone.secureCloud, route: .cloudKit(.private))
        self.outbox = outbox
        feed = RelayFeed(transport: phone.secureCloud, store: phone.replica, outbox: outbox)
        _ = try phone.replica.adoptRoute(TransportKind.cloudKit.rawValue)
        await wire(feed)
    }

    private static func makeOutbox(
        _ phone: ICloudPhone, _ secure: SecureTransport, route: HubRoute, offset: TimeInterval = 0
    ) async throws -> ActionOutbox {
        let outbox = ActionOutbox(
            transport: secure, store: phone.replica, deviceID: phone.link.deviceID.uuidString, route: route
        ) { Date().addingTimeInterval(offset) }
        await outbox.setHubID(phone.code.hubID)
        try await outbox.enableOrderedActions()
        return outbox
    }

    private func wire(_ feed: RelayFeed) async {
        await feed.setTransportHandler { [weak self] control in
            guard let self else { return false }
            return await self.handle(control, on: await self.route)
        }
        await feed.setRejectionHandler { [weak self] control in
            await self?.rejected(control)
            return true
        }
    }

    private func rejected(_ control: ControlPayload) {
        rejection = control
        relayRequested = false
    }

    /// Outboxes made from now on stamp the real time plus `offset`.
    func setClockOffset(_ offset: TimeInterval) {
        clockOffset = offset
    }

    func attachRelay(_ transport: HostedRelayTransport, mac: String) {
        relay = (transport, mac)
    }

    /// The next move's new outbox starts held (the old-epoch step releases it).
    func holdNextOutbox() {
        holdNext = true
    }

    func stop() async {
        await outbox.drain()
    }

    private func secure(_ kind: TransportKind) throws -> SecureTransport {
        switch kind {
        case .cloudKit: return phone.secureCloud
        case .relay:
            guard let relay else { throw GoHubInteropFailure.goFailed("no relay transport") }
            return phone.secure(relay.transport)
        }
    }

    /// `transport_switch{target}` with `id`, sealed and written straight into `kind`'s mailbox (rule 9's other copy).
    func writeRequestCopy(target: TransportKind, id: String, on kind: TransportKind) async throws {
        let control = try await outbox.switchRequest(target: target, id: id)
        let side = try secure(kind)
        let sealed = try await side.seal(try CloudRecordFactory.record(for: control, modifiedAt: Date()))
        _ = try await side.saveSealed([ConditionalSave(record: sealed, expect: .absent)])
        if target == .relay { relayRequested = true }
    }

    /// One feed cycle on the route (and the other mailbox's controls, rule 12) every second until `done`.
    func pollUntil(within limit: TimeInterval, _ what: String, _ done: (KitFollower) async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            if let target = adoptRoute {
                adoptRoute = nil
                _ = try phone.replica.adoptRoute(target.rawValue)
            }
            do {
                let routed = try await feed.pollOnce()
                if routed > 0 { Self.trace("\(what): \(routed) echoes routed on \(route.rawValue)") }
            } catch {
                Self.trace("\(what): feed cycle on \(route.rawValue) failed: \(error)")
            }
            if try await done(self) { return }
            await readOtherControls()
            if try await done(self) { return }
            guard Date() < deadline else {
                let rows = (try? phone.replica.outboxRows([.queued, .sent, .settled, .undelivered])) ?? []
                Self.trace("\(what): timed out; rows \(rows.map { "\($0.actionSeq):\($0.delivery.rawValue)@\($0.epoch)" })")
                if let scan = try? await secure(route).relayHygieneScan() {
                    let opened = scan.opened.map { "\($0.kind):\($0.recordName)" }
                    Self.trace("\(what): mailbox on \(route.rawValue): opened \(opened), unopenable \(scan.unopenable.map(\.reason))")
                }
                throw GoHubInteropFailure.timedOut(what)
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// A line on stderr (the interop run's log; nothing secret: kinds, counts, seqs, epochs).
    static func trace(_ line: String) {
        FileHandle.standardError.write(Data("kit follower: \(line)\n".utf8))
    }

    /// The other transport's mailbox, controls only (a lapse refuses the relay; the hub's notice is on both).
    private func readOtherControls() async {
        let other: TransportKind = route == .cloudKit ? .relay : .cloudKit
        guard other == .cloudKit || relay != nil else { return }
        do {
            if other == .relay { try await relay?.transport.pull(only: [.relay]) }
            let route = route
            _ = try await feed.readControls(over: try secure(other)) { [weak self] control in
                guard let self else { return false }
                return await self.handle(control, on: route == .cloudKit ? .relay : .cloudKit)
            }
        } catch {
            Self.trace("other mailbox not read: \(error)")
        }
    }

    /// The route's mailbox, controls only (`RelayFeed.readControls`): echoes there stay unread.
    func readRouteControls() async throws {
        let route = route
        _ = try await feed.readControls(over: try secure(route)) { [weak self] control in
            guard let self else { return false }
            return await self.handle(control, on: route)
        }
    }

    /// Rule 15: the mailbox on the transport left, through the route's feed.
    func drainLeft() async throws -> RelayFeed.DrainOutcome {
        guard let left else { return .drained }
        if left == .relay { try await relay?.transport.pull(only: [.relay]) }
        let outcome = try await feed.drainMailbox(over: try secure(left), keepingDeviceRecord: left == .cloudKit) { [weak self] control in
            guard let self else { return false }
            return await self.handle(control, on: left)
        }
        if case .drained = outcome {
            self.left = nil
        }
        return outcome
    }

    /// The relay data zone's transport marker (rule 12a), when it names a newer epoch.
    func followMarkerOnRelay() async throws {
        guard let relay else { return }
        try await relay.transport.pull(only: [.data])
        // The marker is a DataZone envelope sealed in the epoch the switch left: the replica's opener opens it
        // (frame kind `transport`), as the hydrator's store does.
        let batch = try await relay.transport.changes(in: .data, since: nil)
        var found: TransportMarker?
        for record in batch.changed where !record.recordName.hasPrefix("\(WireKind.signal)-") {
            guard let frame = try? phone.link.opener.open(wireName: record.recordName, envelope: record.payload),
                  frame.kind == TransportMarker.kind else { continue }
            found = try TransportMarker.decode(frame.payload)
        }
        guard let marker = found else {
            Self.trace("no marker in the relay data zone (\(batch.changed.count) records)")
            return
        }
        _ = await decide(.marker(target: marker.target, epoch: marker.epoch, by: marker.by, at: marker.at, on: .relay), keybox: nil)
    }

    // MARK: Deciding

    func handle(_ control: ControlPayload, on transport: TransportKind) async -> Bool {
        switch control.kind {
        case .hubOnRelay:
            return await decide(.hubOnRelay(controlID: control.id), keybox: nil)
        case .transportSwitched:
            guard let raw = control.target, let target = TransportKind(rawValue: raw), let epoch = control.epoch,
                  let by = control.by, let at = control.at else { return true }
            var keybox: Keybox?
            if let text = control.keybox, let sealed = WireBytes.fromBase64URL(text) {
                keybox = try? await secure(route).openKeybox(sealed: sealed, deviceID: phone.link.deviceID)
            }
            return await decide(
                .switched(target: target, epoch: epoch, by: by, at: at, keyboxOpened: keybox != nil, controlID: control.id, on: transport),
                keybox: keybox)
        default:
            return false
        }
    }

    private func decide(_ input: FollowerInput, keybox: Keybox?) async -> Bool {
        guard let epoch = try? phone.newestEpoch() else { return false }
        let state = FollowerState(
            route: route, newestEpoch: epoch, canUseRelay: canUseRelay, leftTransport: left,
            relaySwitchRequested: relayRequested)
        let (next, commands) = TransportFollowerPolicy.decide(input, state: state, now: Date())
        Self.trace("\(input) on route \(route.rawValue) epoch \(epoch): \(commands)")
        guard !commands.isEmpty else { return false }
        do {
            return try await execute(commands, next: next, input: input, keybox: keybox)
        } catch {
            Self.trace("follow failed: \(error)")
            return false
        }
    }

    private func execute(_ commands: [FollowerCommand], next: FollowerState, input: FollowerInput, keybox: Keybox?) async throws -> Bool {
        var handled = false
        var ack: UInt32?
        var move: (to: TransportKind, by: String)?
        var resend = false
        for command in commands {
            switch command {
            case let .moveRoute(to, _, by, _): move = (to, by)
            case .resendUnechoedOnNewTransport: resend = true
            case .sendEpochAck(let epoch): ack = epoch
            case .listUnechoedAsUndelivered: _ = try await outbox.listUnechoedAsUndelivered(reason: .hubOnRelay)
            case .markHandled, .ignore, .requestAnswered: handled = true
            case .mergeKeybox, .drainMailbox, .pollOtherMailbox: break
            }
        }
        if move?.to == .relay || commands.contains(.requestAnswered) { relayRequested = false }
        if let move, move.to != route {
            try await moveRoute(to: move.to, resend: resend)
        }
        if let move, !move.by.isEmpty { switchedBy = move.by }
        left = next.leftTransport
        if commands.contains(.mergeKeybox) {
            guard let keys = keybox?.keys else { return false }
            try phone.link.merge(keys)
        }
        if let ack {
            if try phone.newestEpoch() < ack {
                // A marker carries no keybox: the new route's data zone holds this phone's.
                let box = try await phone.keybox(over: try inner(route)) { ($0.keys?.epoch ?? 0) >= ack }
                try phone.link.merge(try XCTUnwrap(box.keys))
            }
            try await outbox.enqueueEpochAck(epoch: ack)
        }
        if case .marker = input { return true }
        return handled
    }

    private func inner(_ kind: TransportKind) throws -> any CloudSyncTransport {
        switch kind {
        case .cloudKit: return phone.cloud
        case .relay:
            guard let relay else { throw GoHubInteropFailure.goFailed("no relay transport") }
            return relay.transport
        }
    }

    /// The old outbox writes nothing more; a new outbox and feed on the new route's transport, on the same replica.
    private func moveRoute(to target: TransportKind, resend: Bool) async throws {
        await outbox.holdFlushes()
        let secure = try secure(target)
        let hubRoute: HubRoute
        switch target {
        case .cloudKit: hubRoute = .cloudKit(.private)
        case .relay:
            guard let relay else { throw GoHubInteropFailure.goFailed("no relay transport") }
            hubRoute = .hostedRelay(macDeviceID: relay.mac)
        }
        let next = try await Self.makeOutbox(phone, secure, route: hubRoute, offset: clockOffset)
        if holdNext {
            holdNext = false
            await next.holdFlushes()
        }
        if resend {
            _ = try await next.resendUnechoed(onNewTransport: target)
            lastResent = try phone.replica.outboxRows([.queued])
        }
        // The replica takes the route before the new feed first reads, after the cycle that decided the move
        // stored its token (the app's new session adopts it as it opens).
        adoptRoute = target
        let relayTransport = relay?.transport
        var pull: (@Sendable () async throws -> Void)?
        if target == .relay, let relayTransport {
            pull = { try await relayTransport.pull() }
        }
        let feed = RelayFeed(transport: secure, store: phone.replica, outbox: next, pull: pull)
        await wire(feed)
        outbox = next
        self.feed = feed
        route = target
        Self.trace("moved to \(target.rawValue)")
    }
}
