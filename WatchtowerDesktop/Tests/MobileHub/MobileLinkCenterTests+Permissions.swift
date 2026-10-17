import Foundation
@testable import WatchtowerDesktop
import WatchtowerSync
import XCTest

/// Answering permission prompts (#517, spec §5.1): the phone's request, the
/// owner's separate grant, and the phone's toggle off revoking it.
extension MobileLinkCenterTests {
    /// The phone's "Answer permission prompts from this phone" is a request
    /// the owner sees on its row; it is never a grant by itself.
    func testAPermissionsRequestIsStoredNotGranted() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        nudges = []

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, permissionsRequested: true))

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertTrue(device.permissionsRequested, "the request is kept for Settings → Mobile")
        XCTAssertFalse(device.permissionsAllowed, "a request is never a grant")
        XCTAssertNil(device.decidedAt, "a request decides nothing")
        XCTAssertFalse(try XCTUnwrap(try grants()[phoneA]).permissionsAllowed)
        XCTAssertFalse(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).permissionsAllowed)
    }

    /// The two grants are separate: allowing one leaves the other off.
    func testPermissionsAllowIsSeparateFromTyping() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        nudges = []

        try center.setPermissionsAllowed(true, deviceID: phoneA)

        var device = try XCTUnwrap(center.devices.first)
        XCTAssertTrue(device.permissionsAllowed)
        XCTAssertFalse(device.typingAllowed, "answering prompts does not imply typing")
        XCTAssertEqual(device.decidedAt, clock.now)
        XCTAssertTrue(nudges.contains([.deviceGrant]))
        var grant = try XCTUnwrap(try grants()[phoneA])
        XCTAssertTrue(grant.permissionsAllowed)
        XCTAssertFalse(grant.typingAllowed)
        XCTAssertEqual(
            MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA),
            .init(typingAllowed: false, startSessionsAllowed: true, permissionsAllowed: true)
        )

        try center.setPermissionsAllowed(false, deviceID: phoneA)
        try center.setTypingAllowed(true, deviceID: phoneA)

        device = try XCTUnwrap(center.devices.first)
        XCTAssertTrue(device.typingAllowed)
        XCTAssertFalse(device.permissionsAllowed, "typing does not imply answering prompts")
        grant = try XCTUnwrap(try grants()[phoneA])
        XCTAssertFalse(grant.permissionsAllowed)
        XCTAssertFalse(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).permissionsAllowed)
    }

    /// The phone's toggle going from on to off revokes the grant, as for
    /// typing; a rewrite for another toggle keeps it, and the typing grant is
    /// left alone.
    func testThePhonesPermissionsToggleOffRevokes() async throws {
        var typingRevoked: [String] = []
        center.onTypingRevoked = { typingRevoked.append($0) }
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        try center.setTypingAllowed(true, deviceID: phoneA)
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, permissionsRequested: true))
        try center.setPermissionsAllowed(true, deviceID: phoneA)

        // Another toggle: the request stays on, the grant stays.
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, startSessions: false, permissionsRequested: true))
        XCTAssertEqual(center.devices.first?.permissionsAllowed, true)

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, startSessions: false, permissionsRequested: false))

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertFalse(device.permissionsAllowed)
        XCTAssertFalse(device.permissionsRequested)
        XCTAssertTrue(device.typingAllowed, "typing is its own grant")
        XCTAssertTrue(typingRevoked.isEmpty, "held lines are typing's: untouched")
        XCTAssertFalse(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).permissionsAllowed)
    }

    /// A grant the phone never asked for (the owner allowed it on the Mac)
    /// survives a rewrite with the request off: only on → off revokes.
    func testAnUnrequestedPermissionsGrantSurvivesARewrite() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        try center.setPermissionsAllowed(true, deviceID: phoneA)

        try await handleDevice(try deviceRecord(phoneA, nonce: nil, startSessions: false))

        XCTAssertEqual(center.devices.first?.permissionsAllowed, true)
    }
}
