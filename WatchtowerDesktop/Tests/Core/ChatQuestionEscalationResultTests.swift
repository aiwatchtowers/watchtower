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

    // MARK: Go's goldens (cmd/testdata/escalate, written from the verb's constants)

    private static let goldens = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("cmd/testdata/escalate")

    private struct Contract: Decodable {
        let reasons: [String]
        let errorCodes: [String]
        let transient: [String]

        enum CodingKeys: String, CodingKey {
            case reasons, transient
            case errorCodes = "error_codes"
        }
    }

    private func contract() throws -> Contract {
        try JSONDecoder().decode(Contract.self, from: Data(contentsOf: Self.goldens.appendingPathComponent("contract.json")))
    }

    private func golden(_ name: String) throws -> ChatQuestionEscalationResult {
        try JSONDecoder().decode(
            ChatQuestionEscalationResult.self,
            from: Data(contentsOf: Self.goldens.appendingPathComponent(name))
        )
    }

    /// Every envelope Go prints decodes, and its verdict is the one the runner
    /// acts on: filed, gone, or a known code retried exactly when the contract
    /// calls it transient.
    func testEveryGoEnvelopeGoldenDecodes() throws {
        XCTAssertEqual(try golden("filed_quick.json").verdict, .filed(askID: 42))
        XCTAssertEqual(try golden("filed_quick.json").level, .quick)
        XCTAssertEqual(try golden("filed_full.json").level, .full)
        XCTAssertEqual(try golden("gone.json").verdict, .gone)
        let contract = try contract()
        for raw in contract.errorCodes {
            let result = try golden("\(raw).json")
            XCTAssertFalse(result.ok, raw)
            let code = try XCTUnwrap(result.errorCode, raw)
            XCTAssertNotEqual(code, .other(raw), "\(raw) is a code this build does not know")
            XCTAssertEqual(code.isTransient, contract.transient.contains(raw), raw)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.goldens.path)
            .filter { $0.hasSuffix(".json") && $0 != "contract.json" }
        XCTAssertEqual(
            Set(files),
            Set(contract.errorCodes.map { "\($0).json" } + ["filed_quick.json", "filed_full.json", "gone.json"]),
            "a new golden needs an assertion here"
        )
    }

    /// The Desktop passes exactly the reasons the verb takes.
    func testTheReasonsAreTheContracts() throws {
        XCTAssertEqual(ChatQuestionEscalationPolicy.Reason.allCases.map(\.rawValue), try contract().reasons)
    }

    func testUnparsableOutputThrows() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"{"outcome":"filed"}"#), "ok is required")
    }
}
