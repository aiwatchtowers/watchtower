import XCTest
import GRDB
@testable import WatchtowerCore

/// `ExternalConnection.isOK` is the pure status→indicator mapping the Quick
/// Connections card (`QuickConnectionsDetail`) uses to color the status dot,
/// decide whether to show "Sign in again", and pick the tooltip text. This
/// pins that mapping directly at the Core level (M6 of the 2026-09-10 fix
/// wave) — the view-level color/tooltip wiring itself is SwiftUI and out of
/// scope here, but the underlying boolean it's built on is a pure function
/// of `status` and belongs to WatchtowerCore's fast, non-ML test target.
final class ExternalConnectionTests: XCTestCase {

    private func makeConnection(status: String, error: String = "") -> ExternalConnection {
        ExternalConnection(row: Row([
            "id": 1,
            "name": "test-conn",
            "kind": "http",
            "enabled": true,
            "status": status,
            "error": error
        ]))
    }

    func testIsOK_StatusOK_True() {
        XCTAssertTrue(makeConnection(status: "ok").isOK)
    }

    func testIsOK_StatusRevoked_False() {
        // The status an OAuth grant lands on (QC-04) when the pre-launch
        // refresh fails and the connection is dropped from that launch.
        XCTAssertFalse(makeConnection(status: "revoked", error: "sign in again").isOK)
    }

    func testIsOK_StatusError_False() {
        XCTAssertFalse(makeConnection(status: "error", error: "connection refused").isOK)
    }

    func testIsOK_UnknownStatus_False() {
        // Any status other than the literal "ok" must render as not-OK —
        // isOK is not an allowlist-of-bad-values check, it only ever trusts
        // the exact "ok" string.
        XCTAssertFalse(makeConnection(status: "pending-review").isOK)
    }

    func testIsOK_DefaultsToOK_WhenStatusColumnMissing() {
        // ExternalConnection.init defaults a missing "status" column to "ok"
        // (row["status"] ?? "ok") — pin that default explicitly, since it's
        // what makes a pre-migration or legacy row render as healthy rather
        // than crashing or showing an empty status dot.
        let connection = ExternalConnection(row: Row([
            "id": 2,
            "name": "legacy-conn",
            "kind": "stdio",
            "enabled": false,
            "error": ""
        ]))
        XCTAssertEqual(connection.status, "ok")
        XCTAssertTrue(connection.isOK)
    }
}
