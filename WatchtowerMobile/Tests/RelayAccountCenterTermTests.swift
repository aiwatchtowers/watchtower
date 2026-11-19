import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto
import XCTest
@testable import WatchtowerMobile

/// The term's check (relay client Phase 5, Task 17, `RelayAccountCenter.termCheck`): read, send what the claim allows past
/// the refused set, read again; what holds the term (a held purchase, a refused row) and what does not (a renewal, a row
/// refused in this send, an expired purchase); every answered read told to the targets.
@MainActor
final class RelayAccountCenterTermTests: XCTestCase {
    private struct Rig {
        let bed: AccountBed
        let center: RelayAccountCenter
        let mac: String
        let token: UUID
    }

    /// A phone with no entitlement, the Mac `mac` in its slots.
    private func rig(claim: RelayAccountCenter.SubscriptionClaim = .unset) async throws -> Rig {
        let bed = AccountBed()
        let token = try await bed.register()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        let mac = HostedRelayClient(
            origin: try RelayOrigin(bed.fake.origin), signer: Ed25519RelaySigner(key), kind: .mac,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: bed.clock),
            http: bed.fake.http, sockets: bed.fake.sockets, clock: bed.clock
        )
        _ = try await mac.register()
        try await mac.login()
        let phone = try XCTUnwrap(try bed.relay.session()).client.deviceID
        // A slot needs a paying account; then the subscription ends.
        let account = token.uuidString.lowercased()
        try await bed.fake.setEntitlement(accountID: account, state: "active", for: .seconds(86_400))
        try await bed.fake.pair(mac: mac.deviceID, phones: [phone])
        try await bed.fake.setEntitlement(accountID: account, state: "expired", for: .zero)
        if claim != .unset { bed.defaults.set(claim == .holds, forKey: RelayAccountCenter.holdsSubscriptionKey) }
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        return Rig(bed: bed, center: center, mac: mac.deviceID, token: token)
    }

    func testEveryAnsweredReadIsToldToTheTargets() async throws {
        let bed = AccountBed()
        let token = try await bed.register()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "active", for: .seconds(86_400))
        let target = FakeLapseTarget(isOnRelay: true, relayMacDeviceID: "mac")
        bed.targets = [target]
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        XCTAssertEqual(target.answers.last?.paying, true)
        bed.fake.failNext("getAccountState", with: .unspecified)
        let count = target.answers.count
        await center.refresh()
        XCTAssertEqual(target.answers.count, count, "a failed read tells nothing")
    }

    func testOneRefusedReadStands() async throws {
        let rig = try await rig()
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(answer, .refusalStands)
    }

    func testAFailedReadWaits() async throws {
        let rig = try await rig()
        rig.bed.fake.failNext("getAccountState", with: .unspecified, times: 5)
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(answer, .wait)
    }

    /// An unsent renewal goes first; the new read shows paying with the Mac in the slot.
    func testAPaidPhoneWithAnUnsentRenewalKeepsItsLink() async throws {
        let rig = try await rig(claim: .holds)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token, renewal: true)]
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(rig.bed.submitted.count, 1, "sent")
        XCTAssertEqual(answer, .refusalOver)
    }

    func testARenewalThatCannotBeSentKeepsTheTermDue() async throws {
        let rig = try await rig(claim: .holds)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token, renewal: true)]
        rig.bed.fake.failNext("submitTransaction", with: .unspecified)
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(answer, .wait, "a send that did not reach the relay is a failed read")
    }

    /// `refusedIDs` lives in memory and can be old: the term sends the row again, and only this send's answer counts.
    func testAnOldRefusalInMemoryIsSentAgainAtTheTerm() async throws {
        let rig = try await rig(claim: .holds)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token)]
        rig.bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        await rig.center.retryConfirm()
        XCTAssertEqual(rig.bed.submitted.count, 1, "refused once")
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(rig.bed.submitted.count, 2, "sent again past the refused set")
        XCTAssertEqual(answer, .refusalOver, "an entitled answer keeps the link")
    }

    func testARowRefusedInThisSendDoesNotHoldTheTerm() async throws {
        let rig = try await rig(claim: .holds)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token)]
        rig.bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(answer, .refusalStands)
    }

    /// `transferLimit`, `notImplemented` and `updateRequired`: the person paid and the refusal is not about the payment.
    func testATransferLimitWaitsWithNoHeldLine() async throws {
        for code in [Relay_V1_ErrorCode.transferLimit, .attestationFailed, nil] {
            let rig = try await rig(claim: .holds)
            rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token)]
            if let code {
                rig.bed.fake.failNext("submitTransaction", with: code, times: 2)
            } else {
                rig.bed.fake.billingConfigured = false
            }
            let answer = await rig.center.termCheck(mac: rig.mac) { true }
            XCTAssertEqual(answer, .wait, "\(String(describing: code))")
            XCTAssertFalse(rig.center.heldPurchase, "no held line")
            XCTAssertEqual(rig.center.termHold, .refusedRow)
            let unheld = await rig.center.termCheck(mac: rig.mac) { false }
            XCTAssertEqual(unheld, .refusalStands, "a slot loss or a moved Mac is not held")
        }
    }

    /// Only a press moves the subscription: nothing is sent, and this phone's own purchase holds the term.
    func testAMovedAwayPhoneWithAHeldPurchaseWaits() async throws {
        let rig = try await rig(claim: .movedAway)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token)]
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertTrue(rig.bed.submitted.isEmpty, "nothing sent")
        XCTAssertEqual(answer, .wait)
        XCTAssertTrue(rig.center.heldPurchase)
        XCTAssertEqual(rig.center.termHold, .held)
        let unheld = await rig.center.termCheck(mac: rig.mac) { false }
        XCTAssertEqual(unheld, .refusalStands, "no purchase holds a slot loss")
    }

    func testAMovedAwayPhoneWithOnlyARenewalDoesNotWait() async throws {
        let rig = try await rig(claim: .movedAway)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token, renewal: true)]
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(answer, .refusalStands)
        XCTAssertFalse(rig.center.heldPurchase)
    }

    func testAHeldPurchaseThatExpiredNoLongerHolds() async throws {
        let rig = try await rig(claim: .movedAway)
        rig.bed.store.unfinishedResult = [rig.bed.row(token: rig.token, expiresIn: -60)]
        let answer = await rig.center.termCheck(mac: rig.mac) { true }
        XCTAssertEqual(answer, .refusalStands)
        XCTAssertFalse(rig.center.heldPurchase)
    }

    func testPayingWithTheMacInNoSlotStands() async throws {
        let rig = try await rig()
        try await rig.bed.fake.setEntitlement(accountID: rig.token.uuidString.lowercased(), state: "active", for: .seconds(86_400))
        let slotted = await rig.center.termCheck(mac: rig.mac) { false }
        XCTAssertEqual(slotted, .refusalOver)
        let gone = await rig.center.termCheck(mac: "mac-gone") { false }
        XCTAssertEqual(gone, .refusalStands)
    }
}
