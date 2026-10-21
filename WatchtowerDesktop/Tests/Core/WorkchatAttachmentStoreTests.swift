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

    func testSweepRemovesOldKeepsLive() throws {
        let now = Date(timeIntervalSince1970: 1_792_577_700)
        let store = WorkchatAttachmentStore(root: root) { now }
        let old = try store.save(Data([1]), name: "a.png", sessionID: 1)
        let liveOld = try store.save(Data([1]), name: "b.png", sessionID: 2)
        let fresh = try store.save(Data([1]), name: "c.png", sessionID: 3)
        let longAgo = now.addingTimeInterval(-8 * 86_400)
        for url in [old, liveOld] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }

        store.sweep(olderThan: 7 * 86_400, keepingSessions: [2])

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path), "empty folder goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
