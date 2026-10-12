import XCTest
@testable import WatchtowerCore

/// Spec 2026-10-12 §7: a Codex row resumes only when its rollout exists.
final class CodexRolloutTests: XCTestCase {
    private let id = "0199d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e5f"
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wt codex home \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    @discardableResult
    private func rollout(_ name: String, in dateDir: String = "2026/10/12") throws -> URL {
        let dir = home.appendingPathComponent("sessions/\(dateDir)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data("{}\n".utf8).write(to: file)
        return file
    }

    func testCodexRolloutGlobFindsDateDir() throws {
        try rollout("rollout-2026-10-12T09-00-00-\(id).jsonl", in: "2026/10/12")
        XCTAssertTrue(try CodexRollout.exists(sessionID: id, storedPath: nil, codexHome: home))
        let other = "0199d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e60"
        XCTAssertFalse(try CodexRollout.exists(sessionID: other, storedPath: nil, codexHome: home))
    }

    func testStoredPathWins() throws {
        let elsewhere = home.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let file = elsewhere.appendingPathComponent("rollout-x-\(id).jsonl")
        try Data("{}\n".utf8).write(to: file)
        XCTAssertTrue(try CodexRollout.exists(sessionID: id, storedPath: file.path, codexHome: home))
    }

    /// A stored path of another name, a relative one, a directory or a gone
    /// file is ignored; the date folders still decide.
    func testABadStoredPathFallsBackToTheDateFolders() throws {
        let foreign = home.appendingPathComponent("notes.jsonl")
        try Data("{}\n".utf8).write(to: foreign)
        let dir = home.appendingPathComponent("rollout-x-\(id).jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for stored in [foreign.path, "rollout-x-\(id).jsonl", dir.path, "/nonexistent/rollout-x-\(id).jsonl", ""] {
            XCTAssertFalse(try CodexRollout.exists(sessionID: id, storedPath: stored, codexHome: home), stored)
        }
        try rollout("rollout-2026-10-12T09-00-00-\(id).jsonl")
        XCTAssertTrue(try CodexRollout.exists(sessionID: id, storedPath: foreign.path, codexHome: home))
    }

    func testDegenerateHomeAndNames() throws {
        XCTAssertFalse(try CodexRollout.exists(sessionID: id, storedPath: nil, codexHome: home), "no sessions folder")
        try rollout("\(id).jsonl")
        try rollout("rollout-\(id).jsonl.bak")
        try rollout("rollout-x-\(id).jsonl", in: "2026/10")  // one level short
        XCTAssertFalse(try CodexRollout.exists(sessionID: id, storedPath: nil, codexHome: home))
    }

    /// A date folder that exists but cannot be listed is an error, never
    /// "no rollout": a relaunch must not drop the stored id on it.
    func testAnUnreadableFolderThrows() throws {
        let file = try rollout("rollout-2026-10-12T09-00-00-\(id).jsonl")
        let day = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: day.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: day.path) }
        XCTAssertThrowsError(try CodexRollout.exists(sessionID: id, storedPath: nil, codexHome: home))
        XCTAssertTrue(try CodexRollout.exists(sessionID: id, storedPath: file.path, codexHome: home),
                      "a stored path that is still a file needs no listing")
    }

    /// Without a home only the stored path counts: no date folder is read.
    func testNilHomeChecksTheStoredPathAlone() throws {
        let file = try rollout("rollout-2026-10-12T09-00-00-\(id).jsonl")
        XCTAssertTrue(try CodexRollout.exists(sessionID: id, storedPath: file.path, codexHome: nil))
        XCTAssertFalse(try CodexRollout.exists(sessionID: id, storedPath: nil, codexHome: nil))
        XCTAssertFalse(try CodexRollout.exists(sessionID: id, storedPath: "/nonexistent/rollout-x-\(id).jsonl", codexHome: nil))
    }

    func testInvalidIDIsNeverLookedUp() throws {
        let upper = id.uppercased()
        try rollout("rollout-x-\(upper).jsonl")
        XCTAssertFalse(try CodexRollout.exists(sessionID: upper, storedPath: nil, codexHome: home))
        XCTAssertFalse(try CodexRollout.exists(sessionID: "*", storedPath: nil, codexHome: home))
        XCTAssertFalse(try CodexRollout.exists(sessionID: "", storedPath: nil, codexHome: home))
    }

    func testHomeHonoursAnAbsoluteCODEXHOME() {
        XCTAssertEqual(CodexRollout.home(environment: ["CODEX_HOME": "/Users/example/cx"]).path, "/Users/example/cx")
        let fallback = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        XCTAssertEqual(CodexRollout.home(environment: ["CODEX_HOME": "relative"]).path, fallback)
        XCTAssertEqual(CodexRollout.home(environment: [:]).path, fallback)
    }
}
