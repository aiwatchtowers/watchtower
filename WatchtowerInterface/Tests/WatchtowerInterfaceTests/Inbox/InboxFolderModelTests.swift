import WatchtowerInterface
import XCTest

final class InboxFolderModelTests: XCTestCase {
    private typealias Fix = InboxFixtures

    private func model(
        _ feed: Feed,
        folder: Int64 = 1,
        now: String = "2026-11-16T12:00:00Z",
        zone: String = "UTC",
        hidden: InboxHiddenRows = InboxHiddenRows()
    ) throws -> InboxFolderModel {
        InboxFolderModel(
            feed: feed, folderID: folder, platform: .phone, hidden: hidden,
            now: try Fix.date(now), timeZone: try Fix.zone(zone)
        )
    }

    func testTodayEarlierFollowsTheClientZone() throws {
        // 23:30 UTC on the 15th is the 16th 08:30 in Tokyo and the 15th 15:30 in
        // Los Angeles; at 09:00 UTC on the 16th both zones are on the 16th.
        let feed = Fix.feed(folders: [Fix.root], cards: [try Fix.artifact("o1", stamp: "2026-11-15T23:30:00Z")])
        let now = "2026-11-16T09:00:00Z"
        let tokyo = try model(feed, now: now, zone: "Asia/Tokyo")
        XCTAssertEqual(tokyo.sections.map(\.title), ["Today"])
        XCTAssertEqual(tokyo.cards.first?.stamp, "8:30")
        let losAngeles = try model(feed, now: now, zone: "America/Los_Angeles")
        XCTAssertEqual(losAngeles.sections.map(\.title), ["Earlier"])
        XCTAssertEqual(losAngeles.cards.first?.sourceLine, "Waiting for me · Nov 15, 15:30")
    }

    func testClosedRefRowsAreHidden() throws {
        let card = try Fix.artifact("o1", refs: [Fix.ref(.inboxItem, 1), Fix.ref(.inboxItem, 2, open: false), Fix.ref(.track, 3)])
        var hidden = InboxHiddenRows()
        hidden.hideOnOK("track:3")
        let folder = try model(Fix.feed(folders: [Fix.root], cards: [card]), hidden: hidden)
        XCTAssertEqual(folder.cards.first?.refRows.map(\.key), ["inbox_item:1"])
    }

    func testOlderLineWhenMoreIsPositive() throws {
        let folder = try model(try Fix.golden())
        XCTAssertEqual(folder.olderLine, "42 older cards are on your Mac.")
        let none = try model(Fix.feed(folders: [Fix.root], more: [FolderMore(folderID: 1, count: 0)]))
        XCTAssertNil(none.olderLine)
    }

    func testEmptyFolderCopy() throws {
        let folder = try model(Fix.feed(folders: [Fix.root, Fix.folder(10)]), folder: 10)
        XCTAssertEqual(folder.empty?.title, "No cards in Folder 10")
        XCTAssertEqual(
            folder.empty?.body,
            "Automations routed here write their cards into this folder. Routes are set on your Mac."
        )
        XCTAssertNil(try model(Fix.feed(folders: [Fix.root])).empty)
        XCTAssertNil(try model(Fix.feed(folders: [Fix.root, Fix.folder(10)], cards: [try Fix.artifact("o1", folder: 10)]), folder: 10).empty)
    }

    func testApprovalsAndWaitingFirst() throws {
        let cards = [
            try Fix.artifact("o1", stamp: "2026-11-16T11:00:00Z"),
            try Fix.artifact("o2", stamp: "2026-11-14T09:00:00Z"),
            try Fix.approval("a5", folder: 1),
            try Fix.artifact("o3", stamp: "2026-11-16T09:00:00Z", pinned: true),
            try Fix.artifact("o4", stamp: "2026-11-16T11:30:00Z")
        ]
        let folder = try model(Fix.feed(folders: [Fix.root], cards: cards))
        XCTAssertEqual(folder.sections.map(\.title), ["Needs your decision", "Today", "Earlier"])
        XCTAssertEqual(folder.sections.map { $0.cards.map(\.id) }, [["a5", "o3"], ["o4", "o1"], ["o2"]])
        XCTAssertEqual(folder.cards.map(\.id), ["a5", "o3", "o4", "o1", "o2"])
    }

    func testCardsHiddenOnOKAreLeftOut() throws {
        var hidden = InboxHiddenRows()
        hidden.hideOnOK("o1")
        let folder = try model(Fix.feed(folders: [Fix.root], cards: [try Fix.artifact("o1"), try Fix.artifact("o2")]), hidden: hidden)
        XCTAssertEqual(folder.cards.map(\.id), ["o2"])
    }
}
