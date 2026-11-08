import CryptoKit
import Foundation
import WatchtowerHostedRelay
import XCTest
@testable import WatchtowerMobile

/// `slotLost` (relay client Phase 5, Task 13, F41): on `FORBIDDEN` or `SLOT_REMOVED` the center reads the account, and
/// a relay-route hub whose Mac is in none of this phone's slots while it pays hears `relaySlotLost()`.
@MainActor
final class RelayAccountCenterSlotTests: XCTestCase {
    private func payingBed() async throws -> AccountBed {
        let bed = AccountBed()
        let token = try await bed.register()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "active", for: .seconds(86_400 * 30))
        return bed
    }

    private func started(_ bed: AccountBed) async -> RelayAccountCenter {
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        return center
    }

    /// A Mac registered on the bed's relay; its relay device id.
    private func registeredMac(_ bed: AccountBed) async throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        let mac = HostedRelayClient(
            origin: try RelayOrigin(bed.fake.origin), signer: Ed25519RelaySigner(key), kind: .mac,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: bed.clock),
            http: bed.fake.http, sockets: bed.fake.sockets, clock: bed.clock
        )
        _ = try await mac.register()
        try await mac.login()
        return mac.deviceID
    }

    private func phoneID(_ bed: AccountBed) throws -> String {
        try XCTUnwrap(try bed.relay.session()).client.deviceID
    }

    func testForbiddenWithTheMacGoneIsSlotLost() async throws {
        let bed = try await payingBed()
        let gone = FakeLapseTarget(isOnRelay: true, relayMacDeviceID: "mac-gone")
        let iCloud = FakeLapseTarget(isOnRelay: false, relayMacDeviceID: nil)
        bed.targets = [gone, iCloud]
        let center = await started(bed)
        let reads = bed.reads
        bed.emit(.forbidden(zone: .relay))
        try await bed.until("the read and the slot check") { gone.slotLosses == 1 }
        XCTAssertGreaterThan(bed.reads, reads, "the account was read")
        XCTAssertEqual(iCloud.slotLosses, 0, "a session off the relay hears nothing")
        XCTAssertEqual(gone.lapses, 0, "a paying phone is not lapsed")
        XCTAssertEqual(center.phase, .paying(grace: false, macs: []))

        bed.emit(.control(kind: .slotRemoved, detail: "mac-gone"))
        try await bed.until("SLOT_REMOVED reads and checks too") { gone.slotLosses == 2 }
    }

    /// A Mac still in a slot (a hub that has not named this phone a reader yet) does nothing.
    func testForbiddenWithTheMacInASlotDoesNothing() async throws {
        let bed = try await payingBed()
        let mac = try await registeredMac(bed)
        try await bed.fake.pair(mac: mac, phones: [try phoneID(bed)])
        let held = FakeLapseTarget(isOnRelay: true, relayMacDeviceID: mac)
        bed.targets = [held]
        let center = await started(bed)
        let reads = bed.reads
        bed.emit(.forbidden(zone: .relay))
        try await bed.until("the read") { bed.reads > reads }
        bed.emit(.unsupportedVersion) // events run in order: once this one is seen, the FORBIDDEN was handled
        try await bed.until("handled") { center.updateRequired }
        XCTAssertEqual(held.slotLosses, 0)
    }

    func testForbiddenWithAFailedReadDoesNothing() async throws {
        let bed = try await payingBed()
        let gone = FakeLapseTarget(isOnRelay: true, relayMacDeviceID: "mac-gone")
        bed.targets = [gone]
        let center = await started(bed)
        bed.fake.failNext("getAccountState", with: .unspecified, times: 5)
        bed.emit(.forbidden(zone: .relay))
        bed.emit(.unsupportedVersion)
        try await bed.until("handled") { center.updateRequired }
        XCTAssertEqual(gone.slotLosses, 0, "a failed read waits for the next event")
        XCTAssertEqual(gone.lapses, 0)
    }
}
