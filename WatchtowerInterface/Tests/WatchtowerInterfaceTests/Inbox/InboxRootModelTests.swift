import WatchtowerInterface
import XCTest

final class InboxRootModelTests: XCTestCase {
    private typealias Fix = InboxFixtures

    func testBadgeIsTheSumOfWaiting() throws {
        let model = InboxRootModel(feed: try Fix.golden(), platform: .phone)
        // Root waits 1, Needs approval 1; the hidden Work folder never counts.
        XCTAssertEqual(model.badge, 2)
        XCTAssertEqual(model.countBadge, 4)
        let feed = Fix.feed(folders: [
            Fix.root, Fix.folder(2, kind: .approvals, count: 3, waiting: 3),
            Fix.folder(10, position: 1, count: 5, waiting: 2), Fix.folder(11, position: 2, count: 4, waiting: 4, hidden: true)
        ])
        XCTAssertEqual(InboxRootModel(feed: feed, platform: .phone).badge, 5)
        XCTAssertEqual(InboxRootModel(feed: feed, platform: .mac).countBadge, 8)
    }

    func testFoldersOrderedByPosition() throws {
        let feed = Fix.feed(folders: [
            Fix.root, Fix.folder(12, position: 2), Fix.folder(2, kind: .approvals, count: 1, waiting: 1),
            Fix.folder(10, position: 1), Fix.folder(11, position: 1), Fix.folder(13, parent: 10, position: 1),
            Fix.folder(14, parent: 10, position: 0)
        ])
        let model = InboxRootModel(feed: feed, platform: .mac)
        XCTAssertEqual(model.rootFolderID, 1)
        XCTAssertEqual(model.rows.map(\.folder.id), [2, 10, 11, 12])
        XCTAssertEqual(model.rows[1].children.map(\.folder.id), [14, 13])
        XCTAssertEqual(model.rows[1].children.map(\.depth), [1, 1])
    }

    func testNeedsApprovalIsListedOnThePhoneOnlyWhileItHoldsSomething() {
        let feed = Fix.feed(folders: [Fix.root, Fix.folder(2, kind: .approvals), Fix.folder(10, position: 1)])
        XCTAssertEqual(InboxRootModel(feed: feed, platform: .phone).rows.map(\.folder.id), [10])
        XCTAssertEqual(InboxRootModel(feed: feed, platform: .mac).rows.map(\.folder.id), [2, 10])
    }

    func testFoldersPastThreeLevelsRollUpIntoTheThirdLevel() throws {
        let feed = Fix.feed(folders: [
            Fix.root,
            Fix.folder(10, count: 1, waiting: 1),
            Fix.folder(11, parent: 10, count: 1),
            Fix.folder(12, parent: 11, count: 2, waiting: 1),
            Fix.folder(13, parent: 12, count: 3, waiting: 2),
            Fix.folder(14, parent: 13, count: 4, waiting: 4)
        ])
        let model = InboxRootModel(feed: feed, platform: .phone)
        let third = try XCTUnwrap(model.rows.first?.children.first?.children.first)
        XCTAssertEqual(third.folder.id, 12)
        XCTAssertEqual(third.depth, 2)
        XCTAssertEqual(third.count, 9)
        XCTAssertEqual(third.waiting, 7)
        XCTAssertEqual(third.children, [])
        XCTAssertEqual(model.badge, 8)

        // The deeper folders' cards are listed in the level-3 folder.
        let cards = [try Fix.artifact("o13", folder: 13), try Fix.artifact("o14", folder: 14), try Fix.artifact("o12", folder: 12)]
        let withCards = Fix.feed(folders: feed.folders, cards: cards, more: [FolderMore(folderID: 14, count: 5)])
        let folder = InboxFolderModel(
            feed: withCards, folderID: 12, platform: .phone, hidden: InboxHiddenRows(),
            now: try Fix.date("2026-11-16T12:00:00Z"), timeZone: try Fix.zone("UTC")
        )
        XCTAssertEqual(Set(folder.cards.map(\.id)), ["o12", "o13", "o14"])
        XCTAssertEqual(folder.olderLine, "5 older cards are on your Mac.")
    }
}
