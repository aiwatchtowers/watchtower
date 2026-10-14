import CloudKit
import Foundation
@testable import WatchtowerDesktop
import WatchtowerSync
import XCTest

/// Link data tails (#68): the grant slice only reads, renames, the hello's start-sessions choice and the private
/// creator check against the owner.
extension MobileLinkCenterTests {
    /// A8: the grant slice only reads; an expired refusal is left out of it and the relay cycle's prune forgets it.
    func testTheGrantSliceOnlyReadsAndThePruneForgetsAnExpiredRefusal() throws {
        let now = try XCTUnwrap(clock).now
        try sidecar.saveLinkRefusal(HubSyncState.LinkRefusalRecord(
            deviceID: "refused-old", name: "iPhone", scope: .private, reason: .expiredCode,
            at: now.addingTimeInterval(-DeviceGrantSlice.refusalLifetime - 1)))

        XCTAssertNil(try grants()["refused-old"], "an expired refusal is not published")
        XCTAssertEqual(try sidecar.linkRefusals().map(\.deviceID), ["refused-old"], "reading the slice writes nothing")

        center.pruneExpiredAnswers()
        XCTAssertTrue(try sidecar.linkRefusals().isEmpty)
    }

    /// A8: expired refusals never fill `maxLinkRefusals`: a new refused phone is still answered.
    func testExpiredRefusalsHoldNoPlaceUnderTheRefusalCap() async throws {
        let old = clock.now.addingTimeInterval(-DeviceGrantSlice.refusalLifetime - 1)
        for index in 0..<MobileLinkCenter.maxLinkRefusals {
            try sidecar.saveLinkRefusal(HubSyncState.LinkRefusalRecord(
                deviceID: "refused-\(index)", name: "iPhone", scope: .private, reason: .expiredCode, at: old))
        }
        let code = try await center.issueCode()
        clock.advance(601)

        try await handle(try hello(identityA, nonce: code.nonce))

        XCTAssertEqual(try grants()[phoneA]?.linkRefused, .expiredCode)
    }

    /// A9: a renamed phone's own rewrite renames it on the Mac and in its grant.
    func testARenamedPhonesRewriteUpdatesItsNameAndGrant() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce, name: "iPhone"))
        nudges = []

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, name: "Acme\n iPhone"))

        XCTAssertEqual(center.devices.first?.name, "Acme iPhone", "cleaned like a hello's name")
        XCTAssertEqual(try grants()[phoneA]?.name, "Acme iPhone")
        XCTAssertTrue(nudges.contains([.deviceGrant]))
    }

    /// A12: the hello's start-sessions choice is the new link's grant, not the default.
    func testANewLinkKeepsTheHellosStartSessionsChoice() async throws {
        let code = try await center.issueCode()

        try await link(try hello(identityA, nonce: code.nonce, startSessions: false))

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertFalse(device.startSessionsAllowed)
        XCTAssertNil(device.decidedAt, "the phone's choice, not an owner decision")
        XCTAssertEqual(try grants()[phoneA]?.startSessionsAllowed, false)
        XCTAssertEqual(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).startSessionsAllowed, false)
    }

    /// A9: a `private` phone is the Mac's own user: its creator check compares with the owner, never with the user
    /// name its hello claimed.
    func testAPrivatePhoneIsCheckedAgainstTheOwnerNotTheNameItSent() async throws {
        let code = try await center.issueCode()

        try await link(try hello(identityA, nonce: code.nonce, user: "_claimed-acme"))

        let device = try XCTUnwrap(try sidecar.linkedDevice(phoneA))
        XCTAssertEqual(device.userRecordName, "_owner-acme")
        XCTAssertFalse(device.accepts(creator: "_claimed-acme"))
        XCTAssertTrue(device.accepts(creator: "_owner-acme"))
        XCTAssertTrue(device.accepts(creator: CKCurrentUserDefaultName))
    }
}
