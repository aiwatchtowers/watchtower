import Darwin
import Foundation
@testable import WatchtowerCore
import XCTest

/// Open output's read (spec 2026-11-24-workchat-polish §3): only a regular file that resolves inside the session's
/// own Claude Code temp dir is read; links out, other sessions and special files are not.
final class TaskOutputFileTests: XCTestCase {
    private let sid = "5f1c2d3e-0000-4000-8000-00000000abcd"
    private var base = ""
    private var sessionDir = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("task-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        base = try XCTUnwrap(TaskOutputFile.tempBases(environment: [:], osTemp: dir.path).last)
        XCTAssertTrue(base.hasSuffix(dir.lastPathComponent))
        sessionDir = "\(base)/claude-\(getuid())/-p/\(sid)"
        try FileManager.default.createDirectory(atPath: "\(sessionDir)/tasks", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private func read(_ path: String, session: String? = nil, limit: Int = TaskOutputFile.limit) -> TaskOutputFile.Outcome {
        TaskOutputFile.read(path, claudeSessionID: session ?? sid, bases: [base], limit: limit)
    }

    private func write(_ text: String, _ path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testAgentOutputLinkToItsTranscriptOpens() throws {
        try write("{\"a\":1}\n", "\(sessionDir)/agent.jsonl")
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/a1.output",
                                                   withDestinationPath: "\(sessionDir)/agent.jsonl")
        XCTAssertEqual(read("\(sessionDir)/tasks/a1.output"), .text("{\"a\":1}\n", cut: false))
    }

    func testLongFileIsCut() throws {
        try write("abcdef", "\(sessionDir)/tasks/b1.output")
        XCTAssertEqual(read("\(sessionDir)/tasks/b1.output", limit: 4), .text("abcd", cut: true))
        XCTAssertEqual(read("\(sessionDir)/tasks/b1.output", limit: 6), .text("abcdef", cut: false))
    }

    func testLinkOutOfTheSessionDirIsRevealedNotRead() throws {
        try write("secret", "\(base)/outside.txt")
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/x.output",
                                                   withDestinationPath: "\(base)/outside.txt")
        XCTAssertEqual(read("\(sessionDir)/tasks/x.output"), .reveal)
    }

    func testDirectoryLinkOutOfTheSessionDirIsRevealedNotRead() throws {
        try FileManager.default.createDirectory(atPath: "\(base)/elsewhere", withIntermediateDirectories: true)
        try write("secret", "\(base)/elsewhere/y.output")
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/linked", withDestinationPath: "\(base)/elsewhere")
        XCTAssertEqual(read("\(sessionDir)/linked/y.output"), .reveal)
    }

    func testOtherSessionOrNoneIsRevealed() throws {
        try write("x", "\(sessionDir)/tasks/c1.output")
        XCTAssertEqual(read("\(sessionDir)/tasks/c1.output", session: "other"), .reveal)
        XCTAssertEqual(TaskOutputFile.read("\(sessionDir)/tasks/c1.output", claudeSessionID: nil, bases: [base]), .reveal)
        XCTAssertEqual(read("tasks/c1.output"), .reveal)
        XCTAssertEqual(TaskOutputFile.read("\(sessionDir)/tasks/c1.output", claudeSessionID: sid, uid: getuid() + 1,
                                           bases: [base]), .reveal)
    }

    func testFIFOIsUnreadableWithoutBlocking() {
        let fifo = "\(sessionDir)/tasks/f.output"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertEqual(read(fifo), .unreadable)
    }

    func testMissingOrDirectoryIsUnreadable() {
        XCTAssertEqual(read("\(sessionDir)/tasks/gone.output"), .unreadable)
        XCTAssertEqual(read("\(sessionDir)/tasks"), .unreadable)
    }

    func testTempBasesResolveAndDeduplicate() {
        let bases = TaskOutputFile.tempBases(environment: ["CLAUDE_CODE_TMPDIR": base], osTemp: "/tmp")
        XCTAssertEqual(bases, ["/private/tmp", base])
        XCTAssertEqual(TaskOutputFile.tempBases(environment: ["CLAUDE_CODE_TMPDIR": "\(base)/missing"], osTemp: "/tmp"),
                       ["/private/tmp"])
    }
}
