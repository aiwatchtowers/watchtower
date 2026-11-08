import CryptoKit
import Foundation
import WatchtowerE2ETesting
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Losing and regaining reader status on the phone (relay client Phase 5, Task 13), over the live `AppRoot` and `Bed`:
/// the follower's `slotLost`, a relay-only lapse, an opened `hub_on_relay`, the parked mark and the key source.
@MainActor
final class ReaderStatusWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    // MARK: - Withdrawn, listed, keys kept

    func testRelayOnlyLapseWithdrawsAndListsKeepingKeys() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        try await bed.sendTwoActions(session)
        let offer = try XCTUnwrap(try bed.keys.hubLink(hubID)?.offeredKX, "the relay route drew an offer")
        let before = Set(try await bed.relayMailbox().map(\.name))

        await session.lapseRelay()

        let listed = try session.store.pendingActions().filter { $0.delivery == .undelivered }
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed.map(\.undeliveredReason)), [.refused])
        let after = Set(try await bed.relayMailbox().map(\.name))
        XCTAssertEqual(before.subtracting(after).count, 2, "both actions withdrawn: nothing left the hub could apply")
        XCTAssertEqual(try bed.row()?.link.transport, .relay, "the route stays relay")
        XCTAssertEqual(try bed.row()?.link.relayRefused?.cause, .lapse)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.offeredKX, offer, "keys kept")
        XCTAssertFalse(session.waitsForKeybox, "no key source: a pending record stops the feed silently")
    }

    func testSlotLostWithASubscriptionWithdrawsAndLists() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        try await bed.sendTwoActions(session)
        let since = Date()

        await session.relaySlotLost()

        XCTAssertEqual(Set(try session.store.pendingActions().filter { $0.delivery == .undelivered }.map(\.undeliveredReason)), [.refused])
        let refused = try XCTUnwrap(try bed.row()?.link.relayRefused)
        XCTAssertEqual(refused.cause, .slot)
        XCTAssertGreaterThanOrEqual(refused.since.timeIntervalSince1970 + 1, since.timeIntervalSince1970)
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertTrue(try XCTUnwrap(try bed.keys.hubLink(hubID)).hasEphemeralState, "no key erased on a lost slot")

        // A later event keeps the first date.
        await session.lapseRelay()
        XCTAssertEqual(try bed.row()?.link.relayRefused?.since, refused.since)
    }

    func testSlotLostWithARouteWithdrawsMovesAndLists() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        try await bed.sendTwoActions(session)

        await session.relaySlotLost()
        try await bed.root.routeMoves[hubID]?.value(within: 60, "bed.root.routeMoves[hubID]")

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit, "moved without waiting for hub_on_relay")
        XCTAssertNil(try bed.row()?.link.relayRefused, "a link with a route has no term")
        let moved = try bed.session()
        XCTAssertFalse(moved === session, "the session was rebuilt on iCloud")
        XCTAssertEqual(try Bed.rows(moved, .undelivered).count, 2, "withdrawn and listed")
        XCTAssertTrue(try XCTUnwrap(try bed.keys.hubLink(hubID)).hasEphemeralState, "no key erased before the hub's word")
    }

    /// F29c: the slot comes back before the hub acted: the keybox sealed to the offer still opens and merges.
    func testSlotLostThenSlotBackBeforeTheHubActsKeepsTheLink() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        await session.relaySlotLost()
        let offer = try XCTUnwrap(try bed.keys.hubLink(hubID)?.offeredKX?.publicKey)

        let answer = KeyboxRelayKX(
            hubPub: WireBytes.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            devicePub: WireBytes.base64URL(offer))
        var keys = TestPhone.keyboxKeys(epoch: 2)
        keys = KeyboxKeys(
            epoch: 2, dataKey: keys.dataKey, alertKey: keys.alertKey, metaKey: keys.metaKey, previousEpoch: nil,
            previousDataKey: nil, previousAlertKey: nil, relayKX: answer)
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        await bed.root.linking.reconcileKeyboxKeys(hubID: hubID, keybox: Keybox(grant: grant, keys: keys))

        let link = try XCTUnwrap(try bed.keys.hubLink(hubID))
        XCTAssertNotNil(link.epochs.first { $0.epoch == 2 }?.relayKeys, "the pair of the offer is stored")
        XCTAssertEqual(link.currentKX?.publicKey, offer, "the offer was promoted")
    }

    // MARK: - hub_on_relay

    func testHubOnRelayDropsEphemeral() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        // A stored pair, which a plain follow to iCloud would keep (`clearingEphemeral`).
        _ = try bed.keys.updateHubLink(hubID) { link in
            var copy = link
            copy.epochs[0].relayKeys = EpochRelayKeys(
                p2h: Data(repeating: 1, count: 32), h2p: Data(repeating: 2, count: 32),
                hubPub: Data(repeating: 3, count: 32), devicePub: Data(repeating: 4, count: 32))
            return copy
        }
        XCTAssertTrue(try XCTUnwrap(try bed.keys.hubLink(hubID)).hasEphemeralState)
        bed.relayOps.paying = false

        let decided = await session.transportSignals.control(hubOnRelay())
        try await bed.root.routeMoves[hubID]?.value(within: 60, "bed.root.routeMoves[hubID]")

        XCTAssertTrue(decided)
        let link = try XCTUnwrap(try bed.keys.hubLink(hubID))
        XCTAssertFalse(link.hasEphemeralState, "both private keys and every stored pair went")
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
    }

    /// Back on iCloud with the hub still on the relay: static from then on, no offer drawn.
    func testAPhoneBackOnICloudWithTheHubOnRelayStaysStatic() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        bed.relayOps.paying = false
        _ = await session.transportSignals.control(hubOnRelay())
        try await bed.root.routeMoves[hubID]?.value(within: 60, "bed.root.routeMoves[hubID]")
        let iCloud = try bed.session()
        await iCloud.waitForBoot()
        await bed.root.linking.reconcileKeyboxKeys(hubID: hubID, keybox: plainKeybox(epoch: 2))
        try await iCloud.epochAckWork?.value(within: 60, "iCloud.epochAckWork")

        let link = try XCTUnwrap(try bed.keys.hubLink(hubID))
        XCTAssertFalse(link.hasEphemeralState, "no offer on iCloud, no pair")
        XCTAssertEqual(link.epochs.map(\.epoch).max(), 2)
    }

    // MARK: - The parked mark and the key source

    func testALapseClearsTheParkedRow() async throws {
        for input in ["relayLapsed", "withoutHub", "slotLost"] {
            // hub_on_relay reaches a phone with an iCloud route; the others hold for a relay-only link too.
            let bed = try await Bed.make(self, on: .relay, hubTransports: input == "withoutHub" ? ["cloudkit", "relay"] : ["relay"])
            let session = try await bed.orderedSession()
            _ = try await park(bed, session)
            bed.relayOps.paying = false
            switch input {
            case "relayLapsed": await session.lapseRelay()
            case "slotLost": await session.relaySlotLost()
            default: _ = await session.transportSignals.control(hubOnRelay())
            }
            XCTAssertNil(try session.store.relayFeedParkedSince(), "\(input): Now's row goes")
        }
    }

    /// Lapsed, then a record above the newest epoch past the cap: no parked mark, no row, no refetch.
    func testAPhoneWithNoKeySourceDoesNotParkAgain() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        await session.lapseRelay()
        XCTAssertFalse(session.waitsForKeybox)
        _ = try session.store.startRelayWait(at: Date().addingTimeInterval(-2 * SecureTransport.keyboxWaitCap))
        let control = ControlPayload(id: UUID().uuidString, kind: .resendFrom, deviceID: TestE2E.deviceID.uuidString, hubID: hubID, seq: 1)
        try await bed.writeControl(control, on: .relay, epoch: 3)
        try await bed.fetch(session)
        let stoppedAt = try session.store.relayToken()?.value
        XCTAssertNil(try session.store.relayFeedParkedSince(), "no parked mark: the banner already says why")
        try await bed.fetch(session)
        XCTAssertEqual(try session.store.relayToken()?.value, stoppedAt, "stopped: nothing read again")
        XCTAssertNil(try session.store.relayFeedParkedSince())
    }

    // MARK: - Helpers

    private func hubOnRelay() -> ControlPayload {
        ControlPayload(id: UUID().uuidString, kind: .hubOnRelay, deviceID: TestE2E.deviceID.uuidString, hubID: hubID)
    }

    private func plainKeybox(epoch: UInt32) -> Keybox {
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        return Keybox(grant: grant, keys: TestPhone.keyboxKeys(epoch: epoch))
    }

    /// The feed parks on a hub control sealed in epoch 2 once the wait is past its cap.
    private func park(_ bed: Bed, _ session: HubSession) async throws -> Int? {
        _ = try session.store.startRelayWait(at: Date().addingTimeInterval(-2 * SecureTransport.keyboxWaitCap))
        let control = ControlPayload(id: UUID().uuidString, kind: .resendFrom, deviceID: TestE2E.deviceID.uuidString, hubID: hubID, seq: 1)
        try await bed.writeControl(control, on: .relay, epoch: 2)
        try await bed.fetch(session)
        XCTAssertNotNil(try session.store.relayFeedParkedSince(), "parked")
        return try session.store.relayToken()?.value
    }
}
