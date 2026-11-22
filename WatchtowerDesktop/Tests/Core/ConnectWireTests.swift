import Foundation
import WatchtowerCore
import WatchtowerInterface
import XCTest

/// Every line of the Go golden `internal/connectwire/testdata/wire_cases.json`
/// (Go round-trips it in `TestWire_GoldenCases`) decodes into the Swift
/// `ConnectWire` types and encodes back to the same JSON value. A drift
/// between Go `internal/connectwire` and the Swift side fails here.
final class ConnectWireTests: XCTestCase {
    /// …/internal/connectwire/testdata, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Core
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/connectwire/testdata")

    private struct WireCase: Decodable {
        let name: String
        let kind: String
        let line: String
    }

    private func cases() throws -> [WireCase] {
        struct File: Decodable { let cases: [WireCase] }
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("wire_cases.json"))
        let cases = try JSONDecoder().decode(File.self, from: data).cases
        XCTAssertFalse(cases.isEmpty)
        return cases
    }

    /// Decodes `line` as `T`, re-encodes it the way the socket writes it,
    /// and compares both as canonical JSON (Go escapes `<>&`, Swift does
    /// not; the value is what both sides read).
    private func roundTrip<T: Codable>(_ type: T.Type, _ wireCase: WireCase) throws {
        let bytes = Data(wireCase.line.utf8)
        let value = try JSONDecoder().decode(T.self, from: bytes)
        var encoded = try ConnectWire.line(value)
        XCTAssertEqual(encoded.last, UInt8(ascii: "\n"), wireCase.name)
        encoded.removeLast()
        XCTAssertFalse(encoded.contains(UInt8(ascii: "\n")), wireCase.name)
        XCTAssertEqual(String(bytes: try RawJSON(data: encoded).data, encoding: .utf8),
                       String(bytes: try RawJSON(data: bytes).data, encoding: .utf8), wireCase.name)
    }

    func testWireCasesRoundTrip() throws {
        var kinds: [String: Int] = [:]
        for wireCase in try cases() {
            kinds[wireCase.kind, default: 0] += 1
            switch wireCase.kind {
            case "hello": try roundTrip(ConnectWireHello.self, wireCase)
            case "hello_reply": try roundTrip(ConnectWireHelloReply.self, wireCase)
            case "request": try roundTrip(ConnectWireRequest.self, wireCase)
            case "response": try roundTrip(ConnectWireResponse.self, wireCase)
            default: XCTFail("\(wireCase.name): unknown kind \(wireCase.kind)")
            }
        }
        XCTAssertEqual(Set(kinds.keys), ["hello", "hello_reply", "request", "response"])
    }

    /// The error codes in the golden file are exactly the Swift set.
    func testErrorCodesMatchGo() throws {
        var codes: Set<ConnectWireError> = []
        for wireCase in try cases() where wireCase.kind == "response" {
            let response = try JSONDecoder().decode(ConnectWireResponse.self, from: Data(wireCase.line.utf8))
            if let error = response.error {
                XCTAssertNil(response.result, wireCase.name)
                codes.insert(error.code)
            } else {
                XCTAssertNotNil(response.result, wireCase.name)
            }
        }
        XCTAssertEqual(codes, Set(ConnectWireError.allCases))
    }

    /// The server's own hello lines are the pinned ones.
    func testHelloRepliesArePinned() throws {
        let lines = Dictionary(uniqueKeysWithValues: try cases().map { ($0.name, $0.line) })
        for (name, reply) in [("hello_ok", ConnectWireHelloReply.admitted), ("hello_busy", ConnectWireHelloReply.busy)] {
            let pinned = try XCTUnwrap(lines[name])
            XCTAssertEqual(try JSONDecoder().decode(ConnectWireHelloReply.self, from: Data(pinned.utf8)), reply, name)
        }
    }

    func testRequestArgsKeptAsJSON() throws {
        let request = try JSONDecoder().decode(
            ConnectWireRequest.self,
            from: Data(#"{"id":6,"tool":"choose","args":{"what":"jira_boards","select":["10"]}}"#.utf8)
        )
        XCTAssertEqual(request.id, 6)
        XCTAssertEqual(request.tool, "choose")
        XCTAssertEqual(String(bytes: request.args, encoding: .utf8), #"{"select":["10"],"what":"jira_boards"}"#)
    }

    func testUnreadableResultBecomesFailed() {
        let response = ConnectWireResponse.result(id: 3, json: Data("not json".utf8))
        XCTAssertEqual(response.id, 3)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, .failed)
    }

    func testWaitBudgetIsGoWaitBudget() {
        // Go connectwire.WaitBudget; never CallTimeout (55 s, the client's deadline).
        XCTAssertEqual(ConnectWire.waitBudget, .seconds(45))
        XCTAssertEqual(ConnectWire.socketEnv, "WATCHTOWER_CONNECT_SOCKET")
        XCTAssertEqual(ConnectWire.tokenEnv, "WATCHTOWER_CONNECT_TOKEN")
        XCTAssertEqual(ConnectWire.maxLine, 1 << 20)
    }
}
