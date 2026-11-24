import Foundation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

private let closedHomeID = "40E00000-0000-4000-8000-000000000004"

/// A saved link to `hubID` (the code's hub by default).
private func savedLink(hubID: String = TestE2E.hubID.uuidString, macName: String = "Acme Mac") -> LinkRecord {
    LinkRecord(
        hubID: hubID, macName: macName, scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
        nonce: LinkPayload.makeNonce(), dataShareURL: nil, relayShareURL: nil
    )
}

// MARK: - An expired code of a Mac this iPhone is linked to (ask #1804)

/// The Mac does not answer a hello on a closed code, so a linked phone that scans one past its expiry says so at once
/// and leaves its link as it is; any other expired code keeps the plain expired failure.
extension LinkingViewModelTests {
    /// A code 121 s past its expiry on the phone's clock: past the 120 s grace.
    private func expiredCode() -> LinkPayload {
        code(issuedAgo: Double(LinkPayload.lifetime) + 121)
    }

    /// The Mac's keybox for this phone says linked, whatever the phone writes.
    private func macGrantsTheLink() {
        host.mac = { [grant = grantMaker] _ in grant(TestE2E.hubID.uuidString, true, nil) }
    }

    /// Ask #1804: an expired code of a Mac this iPhone is linked to says so at once. No hello, no write, the link
    /// untouched; the message names the linked Mac.
    func testExpiredCodeOfALinkedMacSaysItIsAlreadyLinkedAndTouchesNothing() async throws {
        let stored = savedLink(macName: "Desk Mac")
        host.seed(stored)
        macGrantsTheLink()
        let model = makeModel()

        await model.open(expiredCode().url())

        XCTAssertEqual(model.phase, .failed(.expiredButLinked(macName: "Desk Mac")))
        let failure = LinkFailure.expiredButLinked(macName: "Desk Mac")
        XCTAssertEqual(failure.message, "This code has expired. This iPhone is already linked to Desk Mac.")
        XCTAssertEqual(failure.title, "This code has expired")
        XCTAssertEqual(failure.hint, "This iPhone is already linked to Desk Mac")
        XCTAssertTrue(host.prepared.isEmpty, "no hello")
        let writes = try await host.deviceWrites()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(host.removals.isEmpty, "the link stays")
        XCTAssertEqual(host.rows.map(\.link), [stored])
        XCTAssertEqual(host.rows.map(\.state), [.linked])
    }

    /// A link to another Mac does not count: the plain expired-code failure.
    func testExpiredCodeWhileLinkedToAnotherMacShowsTheExpiredFailure() async throws {
        host.seed(savedLink(hubID: closedHomeID, macName: "Home Mac"))
        let model = makeModel()

        await model.open(expiredCode().url())

        XCTAssertEqual(model.phase, .failed(.expired))
        XCTAssertTrue(host.prepared.isEmpty)
        XCTAssertTrue(host.removals.isEmpty)
    }

    /// A link the Mac removed is not alive: the plain expired-code failure.
    func testExpiredCodeOfAMacThatUnlinkedThisPhoneShowsTheExpiredFailure() async throws {
        host.seed(savedLink(), state: .unlinkedByMac)
        let model = makeModel()

        await model.open(expiredCode().url())

        XCTAssertEqual(model.phase, .failed(.expired))
        XCTAssertTrue(host.removals.isEmpty)
    }

    /// A linked row whose grant is gone (the Mac removed this phone, not yet seen) is not a live link: the plain
    /// expired failure, the row left to the grant check.
    func testExpiredCodeOfALinkedRowWithoutItsGrantShowsTheExpiredFailure() async throws {
        let stored = savedLink()
        host.seed(stored, grantMissingSince: start)
        let model = makeModel()

        await model.open(expiredCode().url())

        XCTAssertEqual(model.phase, .failed(.expired))
        XCTAssertTrue(host.prepared.isEmpty)
        XCTAssertTrue(host.removals.isEmpty)
        XCTAssertEqual(host.rows.map(\.link), [stored])
    }

    /// A link that is ending (the Mac's removal still being applied) is not a live link: the plain expired failure.
    func testExpiredCodeOfAHubWhoseLinkIsEndingShowsTheExpiredFailure() async throws {
        host.seed(savedLink())
        macGrantsTheLink()
        host.parksMarkRemoved = true
        let model = makeModel()
        let removal = Task { await model.removedByMac(TestE2E.hubID.uuidString) }
        try await poll { host.markedRemoved == [TestE2E.hubID.uuidString] }

        await model.open(expiredCode().url())

        XCTAssertEqual(model.phase, .failed(.expired))
        XCTAssertTrue(host.prepared.isEmpty)
        host.parksMarkRemoved = false
        await removal.value
        XCTAssertEqual(host.rows.map(\.state), [.unlinkedByMac])
    }

    /// Clock skew: the same 120 s grace as the plain expiry check. A code just past its expiry on the phone's clock
    /// may still be valid on the Mac's, so a linked phone's scan goes on as before (here a re-pair the Mac answers).
    func testCodeOfALinkedMacInsideTheClockGraceStillProceeds() async throws {
        host.seed(savedLink())
        let payload = code(issuedAgo: Double(LinkPayload.lifetime) + 119)
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1)
    }
}
