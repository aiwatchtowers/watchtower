import XCTest
@testable import WatchtowerSync

/// ActionReason is wire format (mobile POC spec §5.2). A reason this build
/// does not know decodes to nil and the hub's message stays, which is what
/// an older phone shows for a newer reason (plan 2026-11-05 Task G7, §3.5).
final class ActionReasonTests: XCTestCase {
    private func echo(reason: String) throws -> ActionRequestPayload {
        let json = #"{"created_at":1700000000,"id":"A1","kind":"session_input","params":{},"status":"failed","#
            + #""reason":"\#(reason)","error_message":"Codex sessions can't take messages from the phone yet. Type it on the Mac."}"#
        return try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
    }

    func testNotSupportedDecodes() throws {
        XCTAssertEqual(ActionReason.notSupported.rawValue, "not_supported")
        let decoded = try echo(reason: "not_supported")
        XCTAssertEqual(decoded.reason, .notSupported)
        XCTAssertEqual(decoded.status, .failed)
    }

    func testUnknownReasonDecodesToNilAndKeepsMessage() throws {
        let decoded = try echo(reason: "a_reason_from_a_newer_mac")
        XCTAssertNil(decoded.reason)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(
            decoded.errorMessage, "Codex sessions can't take messages from the phone yet. Type it on the Mac."
        )
    }
}
