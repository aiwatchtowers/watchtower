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
        XCTAssertEqual(Set(object.keys), ["row", "run", "executable", "args", "env", "cwd", "cols", "rows"])
    }
}
