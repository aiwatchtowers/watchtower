import Foundation
import XCTest
@testable import WatchtowerCore

final class SessionHostFrameTests: XCTestCase {
    func testOutputFrameBytes() {
        let frame = SessionHostFrame(type: .output, payload: Array("hi".utf8))
        XCTAssertEqual(frame.encoded(), [0x84, 0, 0, 0, 2, 0x68, 0x69])
    }

    func testDecoderSplitsAcrossChunks() throws {
        let a = SessionHostFrame(type: .output, payload: Array("hi".utf8))
        let b = SessionHostFrame(type: .exit, payload: Array(#"{"code":0}"#.utf8))
        var decoder = SessionHostFrameDecoder()
        var got: [SessionHostFrame] = []
        for byte in a.encoded() + b.encoded() {
            got += try decoder.append([byte])
        }
        XCTAssertEqual(got, [a, b])
    }

    func testDecoderRejectsOversize() {
        var decoder = SessionHostFrameDecoder()
        let over = UInt32(SessionHostFrame.maxPayload + 1)
        let header: [UInt8] = [0x84, UInt8(over >> 24), UInt8((over >> 16) & 0xFF), UInt8((over >> 8) & 0xFF), UInt8(over & 0xFF)]
        XCTAssertThrowsError(try decoder.append(header)) {
            XCTAssertEqual($0 as? SessionHostFrameError, .tooLarge(Int(over)))
        }
    }

    func testSessionInfoDecodesGoJSON() throws {
        let json = #"{"row":5,"run":"r","pid":42,"started_at_ms":1700000000000,"exited":true,"code":null}"#
        let info = try JSONDecoder().decode(SessionHostSessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info, SessionHostSessionInfo(row: 5, run: "r", pid: 42, startedAtMs: 1_700_000_000_000, exited: true, code: nil))
    }

    func testSocketPathIsShortAndStable() {
        let tmp = String(repeating: "t", count: 59) + "/"
        let path = SessionHostPaths.socketPath(bundleID: "com.example.app", tempDir: tmp)
        XCTAssertEqual(path, SessionHostPaths.socketPath(bundleID: "com.example.app", tempDir: String(tmp.dropLast())))
        XCTAssertLessThanOrEqual(path.utf8.count, 103)
        XCTAssertNotEqual(path, SessionHostPaths.socketPath(bundleID: "com.example.other", tempDir: tmp))
    }

    func testDecoderSkipsUnknownType() throws {
        let a = SessionHostFrame(type: .output, payload: [1])
        let b = SessionHostFrame(type: .exit, payload: [2, 3])
        var decoder = SessionHostFrameDecoder()
        let bytes = a.encoded() + [0x7E, 0, 0, 0, 2, 9, 9] + b.encoded()
        XCTAssertEqual(try decoder.append(bytes), [a, b])
    }

    func testFrameAtMaxPayloadDecodes() throws {
        let frame = SessionHostFrame(type: .input, payload: [UInt8](repeating: 7, count: SessionHostFrame.maxPayload))
        var decoder = SessionHostFrameDecoder()
        XCTAssertEqual(try decoder.append(frame.encoded()), [frame])
    }

    func testLaunchRequestJSONKeys() throws {
        let req = SessionHostLaunchRequest(row: 1, run: "r", executable: "/bin/sh", args: ["-l"], env: ["A=b"], cwd: "/", cols: 80, rows: 24)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["row", "run", "executable", "args", "env", "cwd", "cols", "rows", "scope", "agent"])
        XCTAssertEqual(object["scope"] as? String, "")
        XCTAssertEqual(object["agent"] as? String, "", "Go `LaunchReq.Agent`: \"\" is a shell's profile")
    }

    /// Protocol v2's payloads keep Go's keys (`internal/sessionhost`
    /// `frame.go`, `deliver.go`): a dual path.
    func testV2MessagesJSONKeys() throws {
        func keys(_ value: some Encodable) throws -> Set<String> {
            try Set(XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]).keys)
        }
        let deliver = DeliverRequest(id: "d1", row: 1, run: "r", launch: 2, text: "x", submitIf: true)
        XCTAssertEqual(try keys(deliver), [
            "id", "row", "run", "launch", "text", "keep_line_breaks", "keep_format", "settle_ms", "submit_if", "hold_if_prompt_text"
        ])
        XCTAssertEqual(try keys(DeliverCheckReply(id: "d1", fresh: true, canSubmit: false)), ["id", "fresh", "can_submit", "answers_dialog"])
        XCTAssertEqual(try keys(SessionHostPromptHint(row: 1, run: "r", dialog: true)), ["row", "run", "dialog"])
        XCTAssertEqual(try keys(SessionHostStopRequest(row: 1, run: "r", launch: 2)), ["row", "run", "launch"])

        let reply = #"{"id":"d1","fresh":true,"can_submit":true}"#
        XCTAssertEqual(try JSONDecoder().decode(DeliverCheckReply.self, from: Data(reply.utf8)),
                       DeliverCheckReply(id: "d1", fresh: true, canSubmit: true), "answers_dialog is omitempty")
        let event = #"{"row":1,"run":"r","kind":"left_typed","beside_text":true}"#
        XCTAssertEqual(try JSONDecoder().decode(SessionHostDeliveryEvent.self, from: Data(event.utf8)),
                       SessionHostDeliveryEvent(row: 1, run: "r", kind: .leftTyped, besideText: true))
        XCTAssertEqual(try JSONDecoder().decode(SessionHostExit.self, from: Data(#"{"code":0,"requested":true}"#.utf8)),
                       SessionHostExit(code: 0, requested: true))
        XCTAssertEqual(try JSONDecoder().decode(SessionHostExit.self, from: Data(#"{"code":null}"#.utf8)),
                       SessionHostExit(code: nil), "a natural exit carries no requested")
        let info = #"{"row":5,"run":"r","pid":42,"started_at_ms":1,"exited":false,"launch":3}"#
        XCTAssertEqual(try JSONDecoder().decode(SessionHostSessionInfo.self, from: Data(info.utf8)).launch, 3)
        for (outcome, want) in [("submitted", DeliverOutcome.submitted), ("typed", .typed), ("held", .held("prompt_has_text")),
                                ("no_session", .noSession), ("no_paste_mode", .noPasteMode), ("later", .noSession)] {
            XCTAssertEqual(DeliverOutcome(DeliveredMessage(id: "d", outcome: outcome, reason: "prompt_has_text")), want, outcome)
        }
    }

    /// The v2 frame types keep Go's bytes (`frame.go`).
    func testV2FrameTypeBytes() {
        let pairs: [(SessionHostFrameType, UInt8)] = [
            (.deliver, 0x09), (.delivered, 0x89), (.deliverCheck, 0x8A), (.deliverCheckReply, 0x0A),
            (.promptHint, 0x0B), (.deliveryEvent, 0x8B), (.stop, 0x0C), (.stopping, 0x8C)
        ]
        for (type, byte) in pairs { XCTAssertEqual(type.rawValue, byte, "\(type)") }
    }

    func testSessionInfoScopeDecodesAndDefaultsToEmpty() throws {
        let scoped = #"{"row":5,"run":"r","pid":42,"started_at_ms":1,"exited":false,"code":null,"scope":"ws-a"}"#
        XCTAssertEqual(try JSONDecoder().decode(SessionHostSessionInfo.self, from: Data(scoped.utf8)).scope, "ws-a")
        let older = #"{"row":5,"run":"r","pid":42,"started_at_ms":1,"exited":false}"#
        XCTAssertEqual(try JSONDecoder().decode(SessionHostSessionInfo.self, from: Data(older.utf8)).scope, "")
    }

    func testWorkspaceScopeIsStableAndPerPath() {
        let a = SessionHostPaths.scope(databasePath: "/tmp/acme/watchtower.db")
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a, SessionHostPaths.scope(databasePath: "/tmp/acme/./watchtower.db"))
        XCTAssertNotEqual(a, SessionHostPaths.scope(databasePath: "/tmp/other/watchtower.db"))
    }
}
