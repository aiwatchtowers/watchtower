import XCTest
@testable import WatchtowerDesktop

/// Edits save themselves, never over somebody else's version (PROJ-03 as
/// amended 2026-10-02).
@MainActor
final class CodeFileBufferTests: XCTestCase {
    private static let delay: Duration = .milliseconds(50)
    private var dir: URL!
    private var file: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("buffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("run.sh")
        try "echo a\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func loaded(_ url: URL? = nil) -> CodeFileBuffer {
        let buffer = CodeFileBuffer(url: url ?? file, relPath: "run.sh", autosaveDelay: Self.delay)
        buffer.loadIfNeeded()
        return buffer
    }

    private func disk(_ url: URL? = nil) throws -> String { try String(contentsOf: url ?? file, encoding: .utf8) }

    /// Waits on state, not on a tight wall-clock margin.
    private func eventually(_ condition: () throws -> Bool, timeout: Duration = .seconds(3)) async rethrows {
        let deadline = ContinuousClock.now + timeout
        while try !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testEditSavesItselfAfterThePauseAndKeepsPermissions() async throws {
        let buffer = loaded()
        buffer.edited("echo b\n", base: 0)
        XCTAssertTrue(buffer.isDirty)
        XCTAssertEqual(try disk(), "echo a\n", "not before the pause")
        try await eventually { !buffer.isDirty }
        XCTAssertEqual(try disk(), "echo b\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testEachEditRestartsTheDelay() async throws {
        let buffer = CodeFileBuffer(url: file, relPath: "run.sh", autosaveDelay: .milliseconds(300))
        buffer.loadIfNeeded()
        buffer.edited("echo b\n", base: 0)
        try await Task.sleep(for: .milliseconds(150))
        buffer.edited("echo bc\n", base: 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try disk(), "echo a\n", "the second edit pushed the save back")
        try await eventually { !buffer.isDirty }
        XCTAssertEqual(try disk(), "echo bc\n")
    }

    func testNowSavesAtOnce() throws {
        let buffer = loaded()
        buffer.edited("echo now\n", base: 0, now: true)
        XCTAssertEqual(try disk(), "echo now\n")
        XCTAssertFalse(buffer.isDirty)
    }

    func testWritesThroughASymlinkToTheRealFile() throws {
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let buffer = loaded(link)
        buffer.edited("echo via link\n", base: 0, now: true)
        XCTAssertEqual(try disk(), "echo via link\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), file.path, "the link stays a link")
    }

    func testProj03FilesEditorNeverWritesOverANewerDiskVersion() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.edited("echo mine\n", base: 0, now: true)
        XCTAssertTrue(buffer.conflict)
        XCTAssertEqual(try disk(), "echo agent\n")
        buffer.edited("echo mine 2\n", base: 0, now: true)
        XCTAssertEqual(try disk(), "echo agent\n", "still refused until the owner decides")
        buffer.keepMine()
        XCTAssertNil(buffer.problem)
        XCTAssertEqual(try disk(), "echo mine 2\n")
    }

    func testAnEditTypedBeforeAReloadIsAConflictNotASave() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.diskChanged()
        XCTAssertEqual(buffer.externalRevision, 1)
        // The page sends what it typed on revision 0, after the reload.
        buffer.edited("echo typed earlier\n", base: 0, now: true)
        XCTAssertTrue(buffer.conflict)
        XCTAssertEqual(try disk(), "echo agent\n")
        XCTAssertEqual(buffer.text, "echo typed earlier\n", "the owner's edit is kept for the banner")
    }

    func testReloadFromDiskDropsTheEditsAndForcesThePage() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.edited("echo mine\n", base: 0, now: true)
        buffer.reloadFromDisk()
        XCTAssertEqual(buffer.text, "echo agent\n")
        XCTAssertFalse(buffer.isDirty)
        XCTAssertNil(buffer.problem)
        XCTAssertEqual(buffer.forcedRevision, buffer.externalRevision)
    }

    func testKeepMineRebasesThePage() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.edited("echo mine\n", base: 0, now: true)
        buffer.keepMine()
        XCTAssertEqual(buffer.rebasedRevision, buffer.externalRevision)
        // An edit on the new base saves normally.
        buffer.edited("echo mine 2\n", base: buffer.externalRevision, now: true)
        XCTAssertEqual(try disk(), "echo mine 2\n")
    }

    func testCleanBufferFollowsTheDiskAndDirtyOneRaisesAConflict() throws {
        let buffer = loaded()
        try "echo agent\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.diskChanged()
        XCTAssertEqual(buffer.text, "echo agent\n")
        XCTAssertNil(buffer.problem)
        buffer.edited("echo mine\n", base: buffer.externalRevision)
        try "echo agent 2\n".write(to: file, atomically: false, encoding: .utf8)
        buffer.diskChanged()
        XCTAssertTrue(buffer.conflict)
        XCTAssertEqual(buffer.text, "echo mine\n")
    }

    func testADeletionUnderEditsIsNeverUndoneByTheAutosave() async throws {
        let buffer = loaded()
        buffer.edited("echo mine\n", base: 0)
        try FileManager.default.removeItem(at: file)
        buffer.diskChanged()
        XCTAssertEqual(buffer.problem, .deletedWhileEditing)
        try await Task.sleep(for: Self.delay * 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(buffer.saveNow(), "an autosave-style save stays refused")
        buffer.keepMine()
        XCTAssertEqual(try disk(), "echo mine\n", "Write it back recreates it")
    }

    func testCmdSWritesBackACleanDeletedFile() throws {
        let buffer = loaded()
        try FileManager.default.removeItem(at: file)
        buffer.diskChanged()
        XCTAssertTrue(buffer.deletedOnDisk)
        buffer.edited("echo back\n", base: 0)
        XCTAssertFalse(buffer.saveNow(), "the autosave does not recreate it")
        buffer.edited("echo back\n", base: 0, explicit: true)
        XCTAssertEqual(try disk(), "echo back\n")
    }

    func testAnUnreadableDiskVersionIsNeverWrittenOver() throws {
        let buffer = loaded()
        buffer.edited("echo mine\n", base: 0)
        try Data([0x65, 0x00, 0x66]).write(to: file)
        buffer.diskChanged()
        guard case .unreadable? = buffer.problem else { return XCTFail("expected unreadable, got \(String(describing: buffer.problem))") }
        XCTAssertFalse(buffer.saveNow())
        XCTAssertEqual(try Data(contentsOf: file), Data([0x65, 0x00, 0x66]))
    }

    func testAFailedWriteReportsAndLeavesTheFileWhole() throws {
        let buffer = loaded()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        buffer.edited("echo mine\n", base: 0, now: true)
        XCTAssertNotNil(buffer.saveError)
        XCTAssertTrue(buffer.isDirty)
        XCTAssertEqual(try disk(), "echo a\n")
        XCTAssertNotNil(buffer.unsavedReason)
    }

    func testReadRefusesBigAndBinaryFiles() throws {
        let big = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: CodeFileBuffer.maxBytes + 1).write(to: big)
        XCTAssertEqual(CodeFileBuffer.read(big), .failure(.tooBig))
        let binary = dir.appendingPathComponent("bin")
        try Data([0, 1, 2]).write(to: binary)
        XCTAssertEqual(CodeFileBuffer.read(binary), .failure(.notText))
        XCTAssertEqual(CodeFileBuffer.read(dir.appendingPathComponent("none")), .failure(.missing))
    }
}
