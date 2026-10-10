import XCTest
import WatchtowerCore

/// The `workbench session-probe` envelope (Go `sessionProbeResult` /
/// `sessionProbeFailure`, spec 2026-10-10-session-background-agents §10).
final class SessionProbeResultTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionProbeResult {
        try JSONDecoder().decode(SessionProbeResult.self, from: Data(json.utf8))
    }

    func testDecodesEveryOutcomeAndTheFailureEnvelope() throws {
        let outcomes: [(String, SessionProbeResult.Outcome)] = [
            ("not_stale", .notStale), ("busy", .busy), ("waiting", .waiting), ("idle", .idle),
            ("shell", .shell), ("unknown", .unknown), ("gone", .gone)
        ]
        for (raw, outcome) in outcomes {
            let result = try decode(
                #"{"ok":true,"outcome":"\#(raw)","ended":false,"agent_background_at":"2026-10-10T12:00:00.000Z"}"#
            )
            XCTAssertEqual(result, SessionProbeResult(ok: true, outcome: outcome,
                                                      agentBackgroundAt: "2026-10-10T12:00:00.000Z"), raw)
            XCTAssertTrue(result.ran, raw)
        }

        let ended = try decode(#"{"ok":true,"outcome":"gone","ended":true,"agent_background_at":"2026-10-10T12:00:00.000Z"}"#)
        XCTAssertTrue(ended.ended)

        let failure = try decode(#"{"ok":false,"error":"terminal session 4 is not in workbench 2"}"#)
        XCTAssertEqual(failure, SessionProbeResult(ok: false, outcome: nil,
                                                   error: "terminal session 4 is not in workbench 2"))
        XCTAssertFalse(failure.ran)
        XCTAssertFalse(failure.ended)

        let newer = try decode(#"{"ok":true,"outcome":"sleeping","ended":false,"agent_background_at":""}"#)
        XCTAssertEqual(newer.outcome, .unknown, "an outcome this build does not know")
        XCTAssertTrue(newer.ran)

        XCTAssertFalse(try decode(#"{"ok":true}"#).ran, "ok without an outcome is no probe")
        XCTAssertThrowsError(try decode(#"{"outcome":"busy"}"#), "no ok: not the envelope")
    }
}
