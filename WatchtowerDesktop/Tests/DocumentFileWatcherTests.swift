import XCTest
@testable import WatchtowerDesktop

/// `DocumentFileWatcher` over a real temp file — no fakes, since its whole job is
/// translating real vnode events (write/delete/rename) into one callback shape.
@MainActor
final class DocumentFileWatcherTests: XCTestCase {
    private var folder: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("watched.txt")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testWriteFiresTheCallback() throws {
        let fired = expectation(description: "write fires")
        let watcher = DocumentFileWatcher(url: fileURL) { fired.fulfill() }
        try "changed".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5)
        watcher.stop()
    }

    /// The editor/Claude-Code atomic-save pattern the watcher's own doc comment
    /// names: write a temp file, then `rename()` it over the watched path. That
    /// unlinks the watched inode (a `.rename` event, firing once), and the
    /// watcher must re-arm on the new inode and keep observing writes to it.
    func testAtomicReplaceReArmsAndStillFiresOnASubsequentWrite() throws {
        var count = 0
        let firstFire = expectation(description: "replace fires")
        let secondFire = expectation(description: "post-replace write fires")
        let watcher = DocumentFileWatcher(url: fileURL, retryInterval: 0.1) {
            count += 1
            if count == 1 { firstFire.fulfill() }
            if count == 2 { secondFire.fulfill() }
        }

        let tmp = folder.appendingPathComponent("watched.txt.tmp")
        try "replaced".write(to: tmp, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(tmp.path, fileURL.path), 0, "rename() must succeed for this test to be meaningful")
        wait(for: [firstFire], timeout: 5)

        // Re-arming after a rename is asynchronous (a retryInterval-paced open loop),
        // so poll-write until the newly-armed watcher observes one, bounded by the
        // expectation timeout below.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            try? "again".write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
        wait(for: [secondFire], timeout: 5)
        timer.invalidate()
        watcher.stop()
    }

    /// A delete alone already fires once (the `.delete` event on the doomed fd);
    /// this pins that the watcher also recovers once the path exists again.
    func testDeleteThenRecreateFiresAfterTheFileReappears() throws {
        var count = 0
        let deleteFire = expectation(description: "delete fires")
        let recreateFire = expectation(description: "fires again after recreate")
        let watcher = DocumentFileWatcher(url: fileURL, retryInterval: 0.1) {
            count += 1
            if count == 1 { deleteFire.fulfill() }
            if count == 2 { recreateFire.fulfill() }
        }

        try FileManager.default.removeItem(at: fileURL)
        wait(for: [deleteFire], timeout: 5)

        try "recreated".write(to: fileURL, atomically: true, encoding: .utf8)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            try? "again".write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
        wait(for: [recreateFire], timeout: 5)
        timer.invalidate()
        watcher.stop()
    }

    /// `stop()` must be a hard cutoff: no callback fires afterward, no matter what
    /// happens to the file. (The descriptor's own closure is an implementation
    /// detail of `setCancelHandler { close(descriptor) } — not independently
    /// observable without exposing it for testing, which would leak the detail
    /// the opposite way; the externally-visible contract is "no more callbacks".)
    func testStopPreventsFurtherCallbacks() throws {
        var count = 0
        var extraFire: XCTestExpectation?
        let firstFire = expectation(description: "first write fires")
        let watcher = DocumentFileWatcher(url: fileURL) {
            count += 1
            if count == 1 { firstFire.fulfill() } else { extraFire?.fulfill() }
        }
        try "changed".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [firstFire], timeout: 5)

        watcher.stop()
        let noMoreCallbacks = expectation(description: "no callback after stop")
        noMoreCallbacks.isInverted = true
        extraFire = noMoreCallbacks
        try "after-stop-1".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fileURL)
        try "after-stop-2".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [noMoreCallbacks], timeout: 1)
        XCTAssertEqual(count, 1, "stop() must prevent every subsequent callback")
    }
}
