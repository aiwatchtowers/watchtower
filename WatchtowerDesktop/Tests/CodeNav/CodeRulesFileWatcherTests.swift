import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `CodeRulesFileWatcher` over a real temp folder (spec §6.5): the rules
/// file created, edited in place, replaced atomically and removed are each
/// reported; another file of the folder changing (the database next to it)
/// is not; a missing folder is not watched.
@MainActor
final class CodeRulesFileWatcherTests: XCTestCase {
    private var folder: URL!
    private var file: URL!
    private var watcher: CodeRulesFileWatcher?
    private var changes = 0

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("code-rules-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("code-languages.yaml")
    }

    override func tearDown() async throws {
        watcher?.stopWatchingRulesFile()
        watcher = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func startWatching() throws {
        watcher = try XCTUnwrap(CodeRulesFileWatcher(file: file) { [weak self] in self?.changes += 1 })
    }

    /// Waits for the change count to reach `count`, then a little longer
    /// to see that it stays there.
    private func expectChanges(_ count: Int, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = await eventually { self.changes >= count }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(reached, message, file: file, line: line)
        XCTAssertEqual(changes, count, message, file: file, line: line)
    }

    func testCreatedEditedInPlaceReplacedAndRemovedAreEachReported() async throws {
        try startWatching()
        try "tcl: {}\n".write(to: file, atomically: false, encoding: .utf8)
        await expectChanges(1, "created")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("# more\n".utf8))
        try handle.close()
        await expectChanges(2, "edited in place")

        try "# replaced\n".write(to: file, atomically: true, encoding: .utf8)
        await expectChanges(3, "replaced by a rename")

        let handleAfterRename = try FileHandle(forWritingTo: file)
        try handleAfterRename.seekToEnd()
        try handleAfterRename.write(contentsOf: Data("# again\n".utf8))
        try handleAfterRename.close()
        await expectChanges(4, "edited in place after the rename: the new file is watched")

        try FileManager.default.removeItem(at: file)
        await expectChanges(5, "removed")
    }

    func testOtherFilesOfTheFolderAreNotReported() async throws {
        try "# rules\n".write(to: file, atomically: true, encoding: .utf8)
        try startWatching()
        let database = folder.appendingPathComponent("watchtower.db-wal")
        try "a".write(to: database, atomically: true, encoding: .utf8)
        try "ab".write(to: database, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: database)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, 0)
    }

    func testAMissingFolderIsNotWatched() {
        let missing = folder.appendingPathComponent("absent/code-languages.yaml")
        XCTAssertNil(CodeRulesFileWatcher(file: missing) {})
    }

    func testStoppedReportsNothing() async throws {
        try startWatching()
        watcher?.stopWatchingRulesFile()
        try "tcl: {}\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, 0)
    }
}
