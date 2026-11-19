import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
@testable import WatchtowerSync
import XCTest

/// The first upgrade from a Go hub on CloudKit (relay client Phase 5 Task 11, the PR C final review's case), run by
/// `make relay-interop-kit-hub RELAY=<relay checkout> RELAY_INTEROP_UPGRADE=1` beside the Go side's
/// `TestInterop_KitPhoneUpgradesOnCloudKit`. One Kit phone links over iCloud and upgrades as the app's `RelayUpgrade`
/// does: pay, the proven relay id, vouch, add_slot, then the reader wait under the PR C fix's rule, then the request
/// and the follow. A hub on CloudKit writes no relay keybox: the first read of `data/<mac>` must be enough. The app's
/// own rule is guarded by `RelayUpgradeWiringTests.testAFirstUpgradeFromAMacOnICloudFindsNoKeyboxAndAsks`; this run pins
/// that test bed's assumption against the real Go hub.
extension KitGoHubInteropTests {
    /// Set to 1 by `RELAY_INTEROP_UPGRADE=1` (with `WT_GO_HUB_INTEROP_DESKTOP=1`).
    static let upgradeVariable = "WT_GO_HUB_INTEROP_UPGRADE"
    /// The stand's bound on becoming a reader (the app's `RelayUpgrade.readerWaitLimit` is 24 h).
    static let readerWait: TimeInterval = 90

    func testKitPhoneUpgradesAGoHubOnCloudKit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env[Self.desktopVariable] == "1", env[Self.upgradeVariable] == "1" else {
            throw XCTSkip("\(Self.upgradeVariable) is not 1: the first upgrade runs only in its own desktop host's run")
        }
        let handoff = Handoff(dir: try handoffDir())
        do {
            try await upgradeFromCloudKit(handoff)
        } catch {
            handoff.write("kit.fail", handoff.step)
            throw error
        }
    }

    private func upgradeFromCloudKit(_ handoff: Handoff) async throws {
        handoff.step = "ck_url"
        _ = try await handoff.wait(LoopbackCloudEndpoint.handoffFile, Self.goWait)
        let endpoint = try LoopbackCloudEndpoint.read(fromHandoff: handoff.dir)
        let clock = HubClock()
        handoff.step = "link"
        let phone = try await ICloudPhone.link(handoff, endpoint: endpoint, files: ("pair.url", "pair.sas", "confirmed"), now: clock.closure)

        handoff.step = "upgrade"
        let grant = try await phone.keybox(over: phone.cloud) { $0.grant.linked }.grant
        let mac = try XCTUnwrap(grant.relayDeviceID)
        let hubAuth = try XCTUnwrap(grant.relayAuthPub.flatMap(WireBytes.fromBase64URL))
        let follower = try await KitFollower(phone: phone, canUseRelay: .yes, keys: FollowerKeys(offers: true, clock: clock))
        let client = try await makeClient(kind: .phone, seed: 1)
        try await pay(client)
        let signer = try backend.signer(seed: 1)
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
        await follower.attachRelay(relayT, mac: mac)

        // The reader wait (`RelayUpgrade.readerConfirmed`, the PR C fix): FORBIDDEN is not read; a read with no keybox
        // of this phone counts as read; a keybox with keys is merged before the request; a keyless one holds the step
        // only while the hub runs on the relay, which this hub (on CloudKit) does not.
        handoff.step = "reader_wait"
        let name = Keybox.recordName(deviceID: phone.link.deviceID.uuidString)
        try await poll(within: Self.readerWait, "the first read of data/<mac>") {
            do {
                try await relayT.pull(only: [.data])
                return true
            } catch HostedRelayError.server(code: .forbidden, _) {
                return false
            }
        }
        let found = try await relayT.changes(in: .data, since: nil).changed.last { $0.recordName == name }
        XCTAssertNil(found, "a Go hub on CloudKit writes no keybox into data/<mac>: RelayUpgradeWiringTests' bed assumes it")
        if let found, let keys = try phone.link.opener.openKeybox(wireName: found.recordName, envelope: found.payload).keys {
            _ = try await follower.mergeRelayKeybox(atLeast: keys.epoch)
        }
        KitFollower.trace("reader wait: keybox in the relay data zone \(found == nil ? "absent" : "present")")

        // Step 4: the request in the iCloud mailbox, its copy in the relay mailbox, one id; then the follow.
        handoff.step = "request"
        let requestID = UUID().uuidString
        _ = try await follower.outbox.enqueueSwitchRequest(target: .relay, id: requestID)
        _ = try await follower.outbox.flush()
        try await follower.writeRequestCopy(target: .relay, id: requestID, on: .relay)
        try await follower.pollUntil(within: Self.stepWait, "the move to the relay") { await $0.route == .relay }
        handoff.write("upgraded", client.deviceID)
        handoff.step = "done"
        _ = try await handoff.wait("go.ok", Self.goWait)
        await follower.stop()
    }
}
