import XCTest
@testable import WatchtowerDesktop

/// POC (code viewer): edits save themselves, never over a newer disk version.
@MainActor
final class CodeFileBufferTests: XCTestCase {
    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-\(UUID().uuidString).sh")
        try "echo a\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func loaded() -> CodeFileBuffer {
        let buffer = CodeFileBuffer(url: file, relPath: file.lastPathComponent)
        buffer.loadIfNeeded()
        return buffer
    }

    private func disk() throws -> String { try String(contentsOf: file, encoding: .utf8) }

    func testEditSavesItselfAfterThePauseAndKeepsPermissions() async throws {
        let buffer = loaded()
        buffer.edited("echo b\n", now: false)
        XCTAssertTrue(buffer.isDirty)
        XCTAssertEqual(try disk(), "echo a\n")
        try await Task.sleep(for: CodeFileBuffer.autosaveDelay + .milliseconds(400))
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(try disk(), "echo b\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testTypingPushesTheSaveBack() async throws {
        let buffer = loaded()
        buffer.edited("echo b\n", now: false)
        try await Task.sleep(for: .milliseconds(600))
        buffer.edited("echo bc\n", now: false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(try disk(), "echo a\n", "a keystroke restarts the delay")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(try disk(), "echo bc\n")
    }

    func testNowSavesAtOnce() throws {
        let buffer = loaded()
        buffer.edited("echo now\n", now: true)
        XCTAssertEqual(try disk(), "echo now\n")
        XCTAssertFalse(buffer.isDirty)
    }

    func testNeverWritesOverANewerDiskVersion() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.edited("echo mine\n", now: true)
        XCTAssertTrue(buffer.conflict)
        XCTAssertEqual(try disk(), "echo agent\n")
        buffer.keepMine()
        XCTAssertFalse(buffer.conflict)
        XCTAssertEqual(try disk(), "echo mine\n")
    }

    func testReloadFromDiskDropsTheEdits() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.edited("echo mine\n", now: true)
        let revision = buffer.externalRevision
        buffer.reloadFromDisk()
        XCTAssertEqual(buffer.text, "echo agent\n")
        XCTAssertFalse(buffer.isDirty)
        XCTAssertFalse(buffer.conflict)
        XCTAssertEqual(buffer.externalRevision, revision + 1)
    }

    func testCleanBufferFollowsTheDiskAndDirtyOneRaisesAConflict() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.diskChanged()
        XCTAssertEqual(buffer.text, "echo agent\n")
        XCTAssertFalse(buffer.conflict)
        buffer.edited("echo mine\n", now: false)
        try "echo agent 2\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.diskChanged()
        XCTAssertTrue(buffer.conflict)
        XCTAssertEqual(buffer.text, "echo mine\n")
    }
}
