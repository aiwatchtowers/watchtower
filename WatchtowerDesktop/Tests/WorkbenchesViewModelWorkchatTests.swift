import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Workchat pastes go with their session (#604 S9). Split from
/// `WorkbenchesViewModelSessionsTests` (its fixtures) for the lint budget.
extension WorkbenchesViewModelSessionsTests {
    /// A session's exit removes what the owner pasted into its Workchat
    /// (#604 S9); another session's files stay.
    func testASessionExitRemovesItsWorkchatFiles() async throws {
        let root = folder.appendingPathComponent("workchat-attachments", isDirectory: true)
        let store = WorkchatAttachmentStore(root: root)
        let gone = try store.save(Data("png".utf8), name: "a.png", sessionID: 41)
        let kept = try store.save(Data("png".utf8), name: "b.png", sessionID: 42)
        let vm = makeVM()
        vm.attachmentStore = store

        vm.sessionExited(41, code: 0)

        let removed = await waitForCondition { !FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path) }
        XCTAssertTrue(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }
}
