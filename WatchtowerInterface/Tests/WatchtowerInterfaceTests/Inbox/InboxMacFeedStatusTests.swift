import WatchtowerInterface
import XCTest

/// The Mac Inbox's feed line (mockup §7): first load, a failed read over the
/// kept list or alone, reconnecting, another version.
final class InboxMacFeedStatusTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private let now = Date(timeIntervalSince1970: 1_763_288_040) // 2025-11-16T10:14:00Z
    private let shownAt = Date(timeIntervalSince1970: 1_763_284_440) // 09:14 UTC
    private let down = TowerFailure(kind: .down, sentence: TowerText.daemonDown)
    private let version = TowerFailure(kind: .version, sentence: TowerText.differentVersion)

    private func status(
        list: Bool, failure: TowerFailure? = nil, state: TowerScreenState = .ready(stale: nil), line: Bool = false
    ) -> InboxMacFeedStatus? {
        InboxMacFeedStatus.resolve(hasList: list, shownAt: list ? shownAt : nil, failure: failure, state: state,
                                   showsReconnectingLine: line, now: now, timeZone: utc)
    }

    func testFirstLoadIsASpinnerAndNoList() {
        XCTAssertEqual(status(list: false, state: .loading),
                       InboxMacFeedStatus(kind: .loading, text: "Loading the Inbox…"))
        XCTAssertNil(status(list: true), "a current list has no line")
    }

    func testFailedReadKeepsTheListWithItsTimeAndRetry() {
        XCTAssertEqual(status(list: true, failure: down), InboxMacFeedStatus(
            kind: .failed,
            text: "Couldn't refresh the Inbox: Watchtower's background service isn't running. Showing the list from 09:14.",
            actionTitle: "Retry"))
        // With no list yet, the reason shows alone.
        XCTAssertEqual(status(list: false, state: .failed(down)),
                       InboxMacFeedStatus(kind: .failed, text: "Watchtower's background service isn't running",
                                          actionTitle: "Retry"))
        // A refused read's sentence drops its own full stop inside the line.
        let refused = TowerFailure(kind: .refused, sentence: "The database is busy.")
        XCTAssertEqual(status(list: true, failure: refused)?.text,
                       "Couldn't refresh the Inbox: The database is busy. Showing the list from 09:14.")
    }

    func testReconnectingKeepsTheListOnceTheLineIsDue() {
        XCTAssertEqual(status(list: true, state: .reconnecting, line: true),
                       InboxMacFeedStatus(kind: .reconnecting, text: "Reconnecting to Watchtower…"))
        XCTAssertNil(status(list: true, state: .reconnecting, line: false), "not before the line is due")
    }

    func testDifferentVersionOffersRestart() {
        XCTAssertEqual(status(list: true, state: .failed(version)), InboxMacFeedStatus(
            kind: .failed, text: "Watchtower's background service is a different version.", actionTitle: "Restart"))
    }
}

/// The button kinds a press names are the wire's (Go `db.InboxAction.Kind`).
final class InboxActionKindTests: XCTestCase {
    func testKindsAreTheWireNames() {
        XCTAssertEqual([InboxActionKind.link, InboxActionKind.chat, InboxActionKind.agent, InboxActionKind.reply,
                        InboxActionKind.target], ["link", "chat", "agent", "reply", "target"])
    }
}
