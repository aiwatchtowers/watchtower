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
        return OwnerConfirmIO.readLine(server, limit: limit, within: nil)
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

    /// The prefix fills the reader's 64 KiB buffer, so the newline lands in a later read whatever the timing.
    func testANewlineInALaterReadEndsTheLine() throws {
        let (server, client) = try pair()
        let prefix = String(repeating: "a", count: 64 * 1024)
        DispatchQueue.global().async { self.send(client, prefix + "def\nrest") }
        XCTAssertEqual(OwnerConfirmIO.readLine(server, limit: 128 * 1024, within: nil),
                       .line(Data((prefix + "def").utf8)))
    }

    func testBytesAfterTheNewlineAreNotPartOfTheLine() throws {
        XCTAssertEqual(try read(["ab\ncd"], limit: 10), .line(Data("ab".utf8)))
    }

    func testAClosedConnectionBeforeTheNewlineIsNoLine() throws {
        XCTAssertEqual(try read(["abc"], limit: 10, closing: true), .noLine)
    }

    /// The deadline is already past (0 s): no clock to wait out.
    func testSilenceRunsOutAsNoLine() throws {
        let (server, _) = try pair()
        XCTAssertEqual(OwnerConfirmIO.readLine(server, limit: 10, within: 0), .noLine)
    }
}
