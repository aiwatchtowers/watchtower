import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerSync
import XCTest

/// Starting sessions from the phone (#565, security review M1): the Mac
/// decides. A start needs the owner's Allow of starting sessions and of
/// typing (a started agent reads the target text the phone wrote); the
/// phone's own "Start sessions" toggle is only its opt-out.
extension MobileLinkCenterTests {
    /// The phone saying "start sessions on" grants nothing: without the
    /// owner's Allow its starts are refused and its grant says so.
    func testAPhonesOwnStartSessionsToggleNeverGrantsAStart() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce, startSessions: true))
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, typingRequested: true, startSessions: true))
        try center.setTypingAllowed(true, deviceID: phoneA)

        let device = try XCTUnwrap(center.devices.first)
        XCTAssertTrue(device.startSessionsAllowed, "the phone's toggle is mirrored")
        XCTAssertFalse(device.startSessionsGranted, "but the owner has not allowed starts")
        XCTAssertFalse(MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).startSessionsAllowed)
        let grant = try XCTUnwrap(try grants()[phoneA])
        XCTAssertFalse(grant.mayStartSessions, "the phone's Start stays off")
        XCTAssertTrue(grant.startSessionsAllowed, "an older phone still reads its own toggle; the Mac refuses its start")
    }

    /// The owner's Allow opens starts only together with typing; revoking
    /// typing, revoking the start grant or the phone's toggle off closes
    /// them again.
    func testStartingSessionsNeedsTheOwnersGrantAndTyping() async throws {
        let code = try await center.issueCode()
        try await link(try hello(identityA, nonce: code.nonce))
        func mayStart() throws -> (gate: Bool, published: Bool) {
            (MobileLinkCenter.sessionGrant(sidecar, deviceID: phoneA).startSessionsAllowed,
             try XCTUnwrap(try grants()[phoneA]).mayStartSessions)
        }

        try center.setStartSessionsGranted(true, deviceID: phoneA)
        XCTAssertTrue(try XCTUnwrap(center.devices.first).startSessionsGranted)
        XCTAssertFalse(try mayStart().gate, "no typing: no starts")
        XCTAssertFalse(try mayStart().published)

        try center.setTypingAllowed(true, deviceID: phoneA)
        XCTAssertTrue(try mayStart().gate)
        XCTAssertTrue(try mayStart().published)

        try center.setTypingAllowed(false, deviceID: phoneA)
        XCTAssertFalse(try mayStart().gate, "typing revoked closes starts")
        try center.setTypingAllowed(true, deviceID: phoneA)
        try center.setStartSessionsGranted(false, deviceID: phoneA)
        XCTAssertFalse(try mayStart().gate, "the start grant revoked")
        XCTAssertFalse(try mayStart().published)

        try center.setStartSessionsGranted(true, deviceID: phoneA)
        try await handleDevice(try deviceRecord(phoneA, nonce: nil, startSessions: false))
        XCTAssertFalse(try mayStart().gate, "the phone's own opt-out still holds")
        XCTAssertTrue(try XCTUnwrap(center.devices.first).startSessionsGranted, "the phone cannot clear the owner's grant")
    }

    /// A sidecar from before #565 gains the owner's grant in place, off: a
    /// linked phone keeps its link and its other grants, and its starts
    /// wait for the owner's one Allow.
    func testASidecarWithoutTheStartGrantGainsItOffAndKeepsTheLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StartGrant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hubstate.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE devices (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    user_record_name TEXT NOT NULL,
                    linked_at REAL NOT NULL,
                    typing_allowed INTEGER NOT NULL DEFAULT 0,
                    start_sessions_allowed INTEGER NOT NULL DEFAULT 1,
                    decided_at REAL,
                    typing_requested INTEGER NOT NULL DEFAULT 0,
                    permissions_allowed INTEGER NOT NULL DEFAULT 0,
                    permissions_requested INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, typing_allowed)
                VALUES ('phone-a', 'iPhone', 'private', '_owner-acme', 1, 1);
                """)
        }

        let reopened = try HubSyncState(path: path)

        let device = try XCTUnwrap(try reopened.linkedDevice("phone-a"), "the link is kept")
        XCTAssertTrue(device.typingAllowed)
        XCTAssertTrue(device.startSessionsAllowed, "the phone's own toggle is kept")
        XCTAssertFalse(device.startSessionsGranted)
        XCTAssertFalse(device.mayStartSessions, "starts wait for the owner's Allow")
        XCTAssertTrue(try reopened.setDeviceGrant(.startSessionsGrant, true, deviceID: "phone-a", at: Date()))
        XCTAssertTrue(try XCTUnwrap(try HubSyncState(path: path).linkedDevice("phone-a")).mayStartSessions)
    }
}
