import Darwin
import Foundation
@testable import WatchtowerCore
import XCTest

/// Open output's read (spec 2026-11-24-workchat-polish §3): only a regular file that resolves inside the session's
/// own Claude Code temp dir is read; links out, other sessions and special files are not.
final class TaskOutputFileTests: XCTestCase {
    private let sid = "5f1c2d3e-0000-4000-8000-00000000abcd"
    /// The one directory this test creates and removes: `<temp>/task-output-<UUID>`, never a temp root.
    private var testDirName = ""
    private var base = ""
    private var sessionDir = ""
    private var claudeDir = ""

    override func setUpWithError() throws {
        testDirName = "task-output-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(testDirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolved here, not through `tempBases`: teardown must never be handed a temp root.
        let resolved = Self.realPath(dir.path) ?? ""
        guard (resolved as NSString).lastPathComponent == testDirName else {
            // The dir this test just made (its own unique name), removed before skipping.
            try? FileManager.default.removeItem(at: dir)
            throw XCTSkip("the test dir did not resolve to itself")
        }
        base = resolved
        sessionDir = "\(base)/claude-\(getuid())/-p/\(sid)"
        claudeDir = "\(base)/home/.claude"
        try FileManager.default.createDirectory(atPath: "\(sessionDir)/tasks", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only the uniquely named dir this test made; anything else (empty, a root, a temp base) is left alone.
        guard !testDirName.isEmpty, (base as NSString).lastPathComponent == testDirName else { return }
        try? FileManager.default.removeItem(atPath: base)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private var projectDir: String { "\(claudeDir)/projects/-p" }

    private func read(_ path: String, session: String? = nil, limit: Int = TaskOutputFile.limit) -> TaskOutputFile.Outcome {
        TaskOutputFile.read(path, claudeSessionID: session ?? sid, projectDir: projectDir, bases: [base],
                            claudeDir: claudeDir, limit: limit)
    }

    private func write(_ text: String, _ path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Claude Code's layout: `<temp>/claude-<uid>/<project>/<sid>/tasks/<id>.output` links to
    /// `~/.claude/projects/<project>/<sid>/subagents/agent-<id>.jsonl`.
    private func transcript(session: String, id: String, project: String = "-p", projects: String? = nil) throws -> String {
        let dir = "\(projects ?? "\(claudeDir)/projects")/\(project)/\(session)/subagents"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = "\(dir)/agent-\(id).jsonl"
        try write("{\"a\":1}\n", file)
        return file
    }

    func testAgentOutputLinkToItsTranscriptOpens() throws {
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/a1.output",
                                                   withDestinationPath: try transcript(session: sid, id: "a1"))
        XCTAssertEqual(read("\(sessionDir)/tasks/a1.output"), .text("{\"a\":1}\n", cut: false))
    }

    func testLinkToAnotherSessionsTranscriptIsNotRead() throws {
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/a2.output",
                                                   withDestinationPath: try transcript(session: "other", id: "a2"))
        XCTAssertEqual(read("\(sessionDir)/tasks/a2.output"), .reveal)
        // Outside `subagents/` of the same session is not read either.
        let beside = "\(claudeDir)/projects/-p/\(sid).jsonl"
        try write("x", beside)
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/a3.output", withDestinationPath: beside)
        XCTAssertEqual(read("\(sessionDir)/tasks/a3.output"), .reveal)
    }

    func testSameSessionUnderAnotherProjectIsNotRead() throws {
        // The same session id has transcripts under both projects; the read is bound to `-p`.
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/p1.output",
                                                   withDestinationPath: try transcript(session: sid, id: "p1"))
        try FileManager.default.createSymbolicLink(atPath: "\(sessionDir)/tasks/q1.output",
                                                   withDestinationPath: try transcript(session: sid, id: "q1", project: "-q"))
        XCTAssertEqual(read("\(sessionDir)/tasks/p1.output"), .text("{\"a\":1}\n", cut: false))
        XCTAssertEqual(read("\(sessionDir)/tasks/q1.output"), .reveal)
    }

    /// #2386 (codex #2): the temp dir is bound to the project the feed read the session from, like the subagents
    /// branch — the same session id under another project's temp dir is not read, nor any without a project.
    func testSameSessionUnderAnotherProjectsTempDirIsNotRead() throws {
        let other = "\(base)/claude-\(getuid())/-q/\(sid)/tasks"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try write("other project\n", "\(other)/r1.output")
        try write("own project\n", "\(sessionDir)/tasks/r1.output")
        XCTAssertEqual(read("\(other)/r1.output"), .reveal)
        XCTAssertEqual(read("\(sessionDir)/tasks/r1.output"), .text("own project\n", cut: false))
        XCTAssertEqual(TaskOutputFile.read("\(sessionDir)/tasks/r1.output", claudeSessionID: sid, projectDir: nil,
                                           bases: [base], claudeDir: claudeDir), .reveal)
    }

    func testWithoutAClaudeDirOrAProjectDirNoTranscriptIsRead() throws {
        let link = "\(sessionDir)/tasks/a4.output"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: try transcript(session: sid, id: "a4"))
        XCTAssertEqual(read(link), .text("{\"a\":1}\n", cut: false), "readable with both")
        XCTAssertEqual(TaskOutputFile.read(link, claudeSessionID: sid, projectDir: projectDir, bases: [base],
                                           claudeDir: nil), .reveal)
        XCTAssertEqual(TaskOutputFile.read(link, claudeSessionID: sid, projectDir: nil, bases: [base],
                                           claudeDir: claudeDir), .reveal)
        // A project dir that is not a direct child of `projects` widens nothing.
        XCTAssertEqual(TaskOutputFile.read(link, claudeSessionID: sid, projectDir: "\(claudeDir)/projects", bases: [base],
                                           claudeDir: claudeDir), .reveal)
    }

    func testLinkedProjectsDirStillOpens() throws {
        let real = "\(base)/real-projects"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let linkedClaude = "\(base)/home2/.claude"
        try FileManager.default.createDirectory(atPath: linkedClaude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(linkedClaude)/projects", withDestinationPath: real)
        let link = "\(sessionDir)/tasks/l1.output"
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: try transcript(session: sid, id: "l1", projects: real))
        XCTAssertEqual(TaskOutputFile.read(link, claudeSessionID: sid, projectDir: "\(linkedClaude)/projects/-p",
                                           bases: [base], claudeDir: linkedClaude), .text("{\"a\":1}\n", cut: false))
    }

    func testRegularFileInTheSessionTempDirOpens() throws {
        try write("ok\n", "\(sessionDir)/tasks/cmd.output")
        XCTAssertEqual(read("\(sessionDir)/tasks/cmd.output"), .text("ok\n", cut: false))
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
        XCTAssertEqual(TaskOutputFile.read("\(sessionDir)/tasks/c1.output", claudeSessionID: nil, projectDir: projectDir,
                                           bases: [base], claudeDir: claudeDir), .reveal)
        XCTAssertEqual(read("tasks/c1.output"), .refused, "a relative path is never resolved")
        XCTAssertEqual(TaskOutputFile.read("\(sessionDir)/tasks/c1.output", claudeSessionID: sid, projectDir: projectDir,
                                           uid: getuid() + 1, bases: [base], spelledBases: [], claudeDir: claudeDir),
                       .refused, "another user's claude-<uid> is not spelled inside")
    }

    /// Final review F6: a transcript-supplied path outside the temp bases' `claude-<uid>/` and Claude Code's
    /// `projects/` — say under ~/Documents, a TCC-protected folder — is refused on its spelling: it never reaches
    /// `realpath`, and it is not revealed either.
    func testAPathOutsideClaudeCodesDirsIsRefusedBeforeAnythingResolvesIt() {
        var resolved: [String] = []
        let spy: (String) -> String? = { path in
            resolved.append(path)
            return TaskOutputFile.realPath(path)
        }
        for path in ["\(NSHomeDirectory())/Documents/notes.txt", "\(base)/outside.txt",
                     "\(sessionDir)/../../../outside.txt", "\(claudeDir)/projects/./-p/x", "/"] {
            XCTAssertEqual(TaskOutputFile.read(path, claudeSessionID: sid, projectDir: projectDir, bases: [base],
                                               spelledBases: [], claudeDir: claudeDir, resolve: spy),
                           .refused, path)
            XCTAssertFalse(resolved.contains(path), "\(path) reached realpath")
        }
        XCTAssertEqual(resolved, Array(repeating: "\(claudeDir)/projects", count: 5),
                       "only Claude Code's own projects dir is resolved")
    }

    /// The temp roots as spelled (`/tmp` for `/private/tmp`) pass the spelling check; the read still resolves.
    func testASpelledTempRootPassesTheSpellingCheck() throws {
        try write("ok\n", "\(sessionDir)/tasks/s1.output")
        let link = "\(base)/tmp-alias"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base)
        let spelled = "\(link)/claude-\(getuid())/-p/\(sid)/tasks/s1.output"
        XCTAssertEqual(TaskOutputFile.read(spelled, claudeSessionID: sid, projectDir: projectDir, bases: [base],
                                           spelledBases: [link], claudeDir: claudeDir), .text("ok\n", cut: false))
        XCTAssertEqual(TaskOutputFile.read(spelled, claudeSessionID: sid, projectDir: projectDir, bases: [base],
                                           spelledBases: [], claudeDir: claudeDir), .refused)
        XCTAssertEqual(TaskOutputFile.tempCandidates(environment: ["CLAUDE_CODE_TMPDIR": "rel"], osTemp: "/var/t/"),
                       ["/tmp", "/var/t/"])
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
        // Relative roots are refused, as Go's `scratchBases` refuses them (it never resolves against the cwd).
        XCTAssertEqual(TaskOutputFile.tempBases(environment: ["CLAUDE_CODE_TMPDIR": "."], osTemp: "relative"),
                       ["/private/tmp"])
    }
}
