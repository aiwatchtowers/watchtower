import CoreServices
import XCTest
@testable import WatchtowerDesktop

final class FolderWatcherTests: XCTestCase {
    private let root = "/w/repo"
    private let hidden: Set<String> = [".build", "node_modules"]

    private func classify(_ paths: [String], flags: FSEventStreamEventFlags = 0) -> FolderWatcher.Batch {
        FolderWatcher.classify(paths.map { ($0, flags) }, rootPath: root, hidden: hidden)
    }

    func testPathsBecomeRelativeAndTheRootIsEmpty() {
        XCTAssertEqual(classify(["/w/repo/a.go", "/w/repo/cmd/main.go", "/w/repo"]).paths, ["a.go", "cmd/main.go", ""])
    }

    func testGitIndexHeadAndRefsMarkAGitChangeOtherGitPathsAreDropped() {
        XCTAssertTrue(classify(["/w/repo/.git/index"]).gitChanged)
        XCTAssertTrue(classify(["/w/repo/.git/HEAD"]).gitChanged)
        XCTAssertTrue(classify(["/w/repo/.git/refs/heads/main"]).gitChanged)
        let objects = classify(["/w/repo/.git/objects/ab/cd"])
        XCTAssertTrue(objects.isEmpty)
    }

    func testHiddenFoldersNestedGitAndASiblingFolderAreDropped() {
        let batch = classify(["/w/repo/.build/x.o", "/w/repo/web/node_modules/y.js", "/w/repo/sub/.git/index", "/w/repo-other/z"])
        XCTAssertTrue(batch.isEmpty)
    }

    func testDroppedEventsAskForARescan() {
        let batch = classify(["/w/repo/src"], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
        XCTAssertTrue(batch.mustRescan)
        XCTAssertTrue(classify(["/w/repo"], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)).mustRescan)
    }

    func testRealPathKeepsPrivateLikeFSEvents() {
        XCTAssertEqual(FolderWatcher.realPath("/tmp"), "/private/tmp")
        XCTAssertEqual(FolderWatcher.realPath("/no/such/path"), "/no/such/path")
    }
}
