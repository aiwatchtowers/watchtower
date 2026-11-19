import WatchtowerInterface
import XCTest

final class InboxHiddenRowsTests: XCTestCase {
    private typealias Fix = InboxFixtures

    func testHiddenUntilAFeedLeavesItOut() throws {
        var hidden = InboxHiddenRows()
        hidden.hideOnOK("inbox_item:1")
        hidden.hideOnOK("o2")
        XCTAssertTrue(hidden.isHidden("inbox_item:1"))
        XCTAssertFalse(hidden.isHidden("inbox_item:9"))

        // The row is still open and the card still listed: both stay hidden.
        let still = Fix.feed(folders: [Fix.root], cards: [try Fix.artifact("o1", refs: [Fix.ref(.inboxItem, 1)]), try Fix.artifact("o2")])
        hidden.observe(feed: still)
        XCTAssertTrue(hidden.isHidden("inbox_item:1"))
        XCTAssertTrue(hidden.isHidden("o2"))

        // The row closed and the card left: both are forgotten.
        let gone = Fix.feed(folders: [Fix.root], cards: [try Fix.artifact("o1", refs: [Fix.ref(.inboxItem, 1, open: false)])])
        hidden.observe(feed: gone)
        XCTAssertFalse(hidden.isHidden("inbox_item:1"))
        XCTAssertFalse(hidden.isHidden("o2"))
        hidden.observe(feed: still)
        XCTAssertFalse(hidden.isHidden("inbox_item:1"))
    }

    func testShownAgainAfterTwoFeedsStillContainIt() throws {
        var hidden = InboxHiddenRows()
        hidden.hideOnOK("track:3")
        let still = Fix.feed(folders: [Fix.root], cards: [try Fix.artifact("o1", refs: [Fix.ref(.track, 3)])])
        hidden.observe(feed: still)
        XCTAssertTrue(hidden.isHidden("track:3"))
        hidden.observe(feed: still)
        XCTAssertFalse(hidden.isHidden("track:3"))
    }
}
