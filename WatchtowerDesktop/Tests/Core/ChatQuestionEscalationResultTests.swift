import XCTest
import WatchtowerCore

/// The `workbench escalate-question` envelope (Go `escalateResult`, spec
/// 2026-10-10-owner-asks-v2 Part 5.3) and what the runner does with it.
final class ChatQuestionEscalationResultTests: XCTestCase {
    private func decode(_ json: String) throws -> ChatQuestionEscalationResult {
        try JSONDecoder().decode(ChatQuestionEscalationResult.self, from: Data(json.utf8))
    }

    func testFiledDecodesTheAskAndItsLevel() throws {
        for (raw, level) in [("quick", OwnerAskLevel.quick), ("full", .full)] {
            let result = try decode(#"{"ok":true,"outcome":"filed","ask_id":42,"level":"\#(raw)"}"#)
            XCTAssertEqual(result, ChatQuestionEscalationResult(ok: true, outcome: .filed, askID: 42, level: level))
            XCTAssertEqual(result.verdict, .filed(askID: 42))
        }
    }

    func testGoneStopsWithNothingFiled() throws {
        let result = try decode(#"{"ok":true,"outcome":"gone"}"#)
        XCTAssertEqual(result, ChatQuestionEscalationResult(ok: true, outcome: .gone))
        XCTAssertEqual(result.verdict, .gone)
    }

    func testEveryErrorCodeAndWhetherItIsRetried() throws {
        let codes: [(String, ChatQuestionEscalationResult.ErrorCode, Bool)] = [
            ("busy", .busy, true), ("open_cap", .openCap, true), ("not_found", .notFound, false),
            ("bad_args", .badArgs, false), ("schema", .schema, false), ("internal", .internal, false),
            ("from_the_future", .other("from_the_future"), false)
        ]
        for (raw, code, transient) in codes {
            let result = try decode(#"{"ok":false,"error_code":"\#(raw)","error":"why"}"#)
            XCTAssertEqual(result, ChatQuestionEscalationResult(ok: false, errorCode: code, error: "why"), raw)
            XCTAssertEqual(code.isTransient, transient, raw)
            let message = "\(raw): why"
            XCTAssertEqual(result.verdict, transient ? .transient(message) : .failed(message), raw)
        }
    }

    func testTheDesktopsOwnFailureEnvelopeIsNotRetried() {
        let result = ChatQuestionEscalationResult.failure("watchtower exited with error: exit 2")
        XCTAssertEqual(result.errorCode, .internal)
        XCTAssertEqual(result.verdict, .failed("internal: watchtower exited with error: exit 2"))
    }

    func testTheDesktopsLaunchFailureIsRetried() {
        let result = ChatQuestionEscalationResult.launchFailure("no exec bit")
        XCTAssertEqual(result.errorCode, .launchFailed)
        XCTAssertTrue(ChatQuestionEscalationResult.ErrorCode.launchFailed.isTransient)
        XCTAssertEqual(result.verdict, .transient("launch failed: no exec bit"))
    }

    func testAnUnknownOutcomeOrNoCodeIsNotRetried() throws {
        XCTAssertEqual(try decode(#"{"ok":true,"outcome":"queued"}"#).verdict, .failed("unknown outcome queued"))
        XCTAssertEqual(try decode(#"{"ok":true}"#).verdict, .failed("no outcome"))
        XCTAssertEqual(try decode(#"{"ok":false}"#).verdict, .failed("no error_code: no error text"))
    }

    /// A newer Go may add keys: they are ignored.
    func testUnknownKeysAreIgnored() throws {
        let result = try decode(#"{"ok":true,"outcome":"filed","ask_id":7,"level":"quick","target_id":3,"extra":{"a":1}}"#)
        XCTAssertEqual(result.verdict, .filed(askID: 7))
    }

    func testUnparsableOutputThrows() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"{"outcome":"filed"}"#), "ok is required")
    }
}
