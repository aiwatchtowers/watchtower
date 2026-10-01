import XCTest
@testable import WatchtowerCore

final class ClaudeTranscriptTests: XCTestCase {
    private var dir: URL!
    private let uuid = "0f1e2d3c-4b5a-4968-8776-655443322110"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/-tmp-acme"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testNoTranscriptIsFalse() {
        XCTAssertFalse(ClaudeTranscript.exists(sessionID: uuid, configDir: dir.path))
    }

    func testTranscriptInAnyProjectDirIsTrue() throws {
        try Data().write(to: dir.appendingPathComponent("projects/-tmp-acme/\(uuid).jsonl"))
        XCTAssertTrue(ClaudeTranscript.exists(sessionID: uuid, configDir: dir.path))
    }

    func testMissingProjectsDirIsFalse() {
        XCTAssertFalse(ClaudeTranscript.exists(sessionID: uuid, configDir: dir.appendingPathComponent("none").path))
    }

    /// The id goes into a path: an invalid one never reaches the file system.
    func testInvalidIDNeverTouchesTheFileSystem() {
        var touched = false
        let found = ClaudeTranscript.exists(
            sessionID: "../../etc/passwd", configDir: dir.path,
            listDirectory: { _ in touched = true; return ["x"] },
            fileExists: { _ in touched = true; return true }
        )
        XCTAssertFalse(found)
        XCTAssertFalse(touched)
    }
}
