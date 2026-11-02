import Foundation
import XCTest
@testable import WatchtowerCore

/// AGENT-07: the request line's limit counts the whole line, its newline
/// included — the same rule as Go `ownerconfirm.MaxRequestBytes`.
final class OwnerConfirmIOTests: XCTestCase {
    private var fds: [Int32] = []

    override func tearDown() {
        fds.forEach { close($0) }
        fds = []
    }

    /// A connected pair: the server's end and the client's end.
    private func pair() throws -> (server: Int32, client: Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw XCTSkip("socketpair failed: \(errno)") }
        fds += ends
        return (ends[0], ends[1])
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
    }

    private func read(_ writes: [String], limit: Int, closing: Bool = false) throws -> OwnerConfirmIO.LineRead {
        let (server, client) = try pair()
        writes.forEach { send(client, $0) }
        if closing { shutdown(client, SHUT_WR) }
        return OwnerConfirmIO.readLine(server, limit: limit, within: 1)
    }

    func testALineOfExactlyTheLimitWithItsNewlineIsRead() throws {
        XCTAssertEqual(try read(["123456789\n"], limit: 10), .line(Data("123456789".utf8)))
    }

    func testALineOneByteOverIsTooLong() throws {
        XCTAssertEqual(try read(["1234567890\n"], limit: 10), .tooLong)
    }

    func testNoNewlineByTheLimitIsTooLong() throws {
        XCTAssertEqual(try read(["12345", "67890"], limit: 10), .tooLong)
    }

    func testANewlineInALaterReadEndsTheLine() throws {
        let (server, client) = try pair()
        send(client, "abc")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { self.send(client, "def\nrest") }
        XCTAssertEqual(OwnerConfirmIO.readLine(server, limit: 10, within: 2), .line(Data("abcdef".utf8)))
    }

    func testBytesAfterTheNewlineAreNotPartOfTheLine() throws {
        XCTAssertEqual(try read(["ab\ncd"], limit: 10), .line(Data("ab".utf8)))
    }

    func testAClosedConnectionBeforeTheNewlineIsNoLine() throws {
        XCTAssertEqual(try read(["abc"], limit: 10, closing: true), .noLine)
    }

    func testSilenceRunsOutAsNoLine() throws {
        let (server, _) = try pair()
        XCTAssertEqual(OwnerConfirmIO.readLine(server, limit: 10, within: 0.2), .noLine)
    }
}
