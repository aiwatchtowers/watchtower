import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// U5 (plan 2026-11-05 Task G7, S4): a line the Mac refused shows the Mac's
/// own message in its failed row, whatever the reason, so a phone that does
/// not know a newer reason (`not_supported` on an older build) still says
/// what to do.
@MainActor
final class SessionInputSenderTests: XCTestCase {
    private let now = Date()
    private static let hubMessage = "Codex sessions can't take messages from the phone yet. Type it on the Mac."

    private func failedRow(reasonOnTheWire reason: String) async throws -> SessionInputModel.LineRow.State? {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let inputs = SessionInputSender.sending(through: outbox, store: store)
        try await inputs.send(sessionID: 11, text: "also check the migration")

        // The echo as the wire carries it, decoded by this build.
        let sent = try XCTUnwrap(store.pendingActions().first).action
        var wire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RelayCoder.makeEncoder().encode(sent)) as? [String: Any]
        )
        wire["status"] = "failed"
        wire["reason"] = reason
        wire["error_message"] = Self.hubMessage
        let echo = try RelayCoder.makeDecoder().decode(
            ActionRequestPayload.self, from: JSONSerialization.data(withJSONObject: wire)
        )
        try await outbox.applyEcho(echo)

        var snapshot = try demoSnapshot(now: now)
        snapshot.pending = try store.pendingActions()
        let session = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(11, workbench: DemoSeed.acmeID))
        let grant = DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: true, startSessionsAllowed: true
        )
        let input = SessionInputModel(
            session: session, snapshot: snapshot, grant: grant, typingRequested: true, delivered: nil, now: now
        )
        return input.lines.first?.state
    }

    func testFailedRowShowsHubMessageForUnknownReason() async throws {
        let unknown = try await failedRow(reasonOnTheWire: "a_reason_from_a_newer_mac")
        XCTAssertEqual(unknown, .failed(Self.hubMessage))

        let known = try await failedRow(reasonOnTheWire: "not_supported")
        XCTAssertEqual(known, .failed(Self.hubMessage))
    }
}
