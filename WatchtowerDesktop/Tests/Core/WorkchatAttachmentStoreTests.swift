import XCTest
@testable import WatchtowerCore

final class WorkchatAttachmentStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-workchat-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveWritesUnderSessionFolder() throws {
        // 2026-10-21 10:15:00 UTC
        let at = Date(timeIntervalSince1970: 1_792_577_700)
        let store = WorkchatAttachmentStore(root: root) { at }
        let bytes = Data([1, 2, 3])

        let first = try store.save(bytes, name: "Pasted image.png", sessionID: 42)
        let second = try store.save(bytes, name: "Pasted image.png", sessionID: 42)

        XCTAssertEqual(first.path, root.appendingPathComponent("42/20261021-101500-1.png").path)
        XCTAssertEqual(second.lastPathComponent, "20261021-101500-2.png")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
    }

    func testWorkchatFileIs0600() throws {
        let store = WorkchatAttachmentStore(root: root)
        let file = try store.save(Data([1]), name: "a.png", sessionID: 5)
        func mode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(root), 0o700)
    }

    /// A one-minute-old file of a session that is no longer live goes; a
    /// live session's old file stays.
    func testSweepRemovesEndedSessionAtOnce() throws {
        let now = Date(timeIntervalSince1970: 1_792_577_700)
        let store = WorkchatAttachmentStore(root: root) { now }
        let ended = try store.save(Data([1]), name: "a.png", sessionID: 1)
        let live = try store.save(Data([1]), name: "b.png", sessionID: 2)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: ended.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)],
                                              ofItemAtPath: live.path)

        store.sweep(keepingSessions: [2])

        XCTAssertFalse(FileManager.default.fileExists(atPath: ended.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    func testRemoveSessionDropsItsFolderOnly() throws {
        let store = WorkchatAttachmentStore(root: root)
        let gone = try store.save(Data([1]), name: "a.png", sessionID: 1)
        let kept = try store.save(Data([1]), name: "b.png", sessionID: 2)
        store.remove(sessionID: 1)
        store.remove(sessionID: 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }
}
