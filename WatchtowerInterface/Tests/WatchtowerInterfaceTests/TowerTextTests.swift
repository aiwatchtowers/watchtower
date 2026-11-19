import WatchtowerInterface
import XCTest

/// Every user-facing string of the tower client is pinned here (mockup §6
/// phone, §7 Mac Inbox states, §8 tray and other screens).
final class TowerTextTests: XCTestCase {
    func testEveryStringIsPinned() {
        XCTAssertEqual(TowerText.reconnecting, "Reconnecting to Watchtower…")
        XCTAssertEqual(TowerText.daemonDown, "Watchtower's background service isn't running")
        XCTAssertEqual(TowerText.differentVersion, "Watchtower's background service is a different version.")
        XCTAssertEqual(TowerText.retry, "Retry")
        XCTAssertEqual(TowerText.restart, "Restart")
        XCTAssertEqual(TowerText.didntConfirmMac, "Didn't confirm — checking again…")
        XCTAssertEqual(TowerText.didntConfirmPhone, "Didn't confirm — check on the Mac.")
        XCTAssertEqual(TowerText.refresh, "Refresh")
        XCTAssertEqual(TowerText.syncPaused, "Sync paused")
        XCTAssertEqual(TowerText.pauseSync, "Pause Sync")
        XCTAssertEqual(TowerText.resumeSync, "Resume Sync")
        XCTAssertEqual(TowerText.unreadableAnswer, "Watchtower sent an answer this app can't read.")
        XCTAssertEqual(TowerText.couldNotSend, "This request couldn't be sent to Watchtower.")
    }

    func testVersionFailureDrawsRestartAndTheOthersRetry() {
        XCTAssertEqual(TowerFailure(kind: .version, sentence: "").actionTitle, TowerText.restart)
        XCTAssertEqual(TowerFailure(kind: .down, sentence: "").actionTitle, TowerText.retry)
        XCTAssertEqual(TowerFailure(kind: .refused, sentence: "").actionTitle, TowerText.retry)
    }
}
