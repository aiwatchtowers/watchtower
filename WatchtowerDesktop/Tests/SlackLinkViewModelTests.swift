import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Per-VM routing pins for `SlackLinkResolver`: a SECOND account's namespaced
/// channel id must link to THAT account's team with the bare id — not account
/// #1's frozen `workspace.id`, and not `id=2:C…`. The shared resolver's ladder is
/// pinned in `Tests/Core/SlackDeepLinkTests`; these catch a VM left unrouted.
final class SlackLinkViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    /// Workspace `T001` + account 1 (`T001`) + account 2 (`T999`); returns account 2's id.
    private static func seedTwoAccounts(_ db: Database) throws -> Int64 {
        try TestDatabase.insertWorkspace(db, id: "T001")
        _ = try TestDatabase.insertSlackAccount(db, teamID: "T001")
        return try TestDatabase.insertSlackAccount(db, teamID: "T999")
    }

    // Sync helper: inside async tests GRDB's async write overload would win.
    private func seed(_ body: (Database) throws -> Int64) throws -> Int64 {
        try dbManager.dbPool.write(body)
    }

    @MainActor
    func testDigestViewModelResolvesSecondAccountTeam() throws {
        let second = try dbManager.dbPool.write { db -> Int64 in
            let second = try Self.seedTwoAccounts(db)
            try TestDatabase.insertDigest(db, channelID: "\(second):C0456")
            return second
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.slackChannelURL(channelID: "\(second):C0456")?.absoluteString,
                       "slack://channel?team=T999&id=C0456")
        XCTAssertEqual(vm.slackMessageURL(channelID: "\(second):C0456", messageTS: "1740577800.000100")?.absoluteString,
                       "slack://channel?team=T999&id=C0456&message=1740577800.000100")
    }

    @MainActor
    func testTracksViewModelResolvesSecondAccountTeam() throws {
        let second = try dbManager.dbPool.write { db -> Int64 in
            let second = try Self.seedTwoAccounts(db)
            try TestDatabase.insertTrack(db)
            return second
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.slackChannelURL(channelID: "\(second):C0456")?.absoluteString,
                       "slack://channel?team=T999&id=C0456")
        XCTAssertEqual(vm.slackMessageURL(channelID: "\(second):C0456", messageTS: "1740577800.000100")?.absoluteString,
                       "slack://channel?team=T999&id=C0456&message=1740577800.000100")
    }

    @MainActor
    func testChannelStatsViewModelResolvesSecondAccountTeam() async throws {
        let second = try seed { db in
            try TestDatabase.insertWorkspace(db, id: "T001")
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T001", currentUserID: "1:U001")
            return try TestDatabase.insertSlackAccount(db, teamID: "T999")
        }

        let vm = ChannelStatsViewModel(dbManager: dbManager)
        vm.load()
        let deadline = Date().addingTimeInterval(10)
        while vm.slackLinks == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(vm.slackURL(for: "\(second):C0456")?.absoluteString,
                       "slack://channel?team=T999&id=C0456")
    }

    /// Catch-Up's archives fallback carries no team, so the pin is that a
    /// second account's prefix is stripped, never passed through.
    func testCatchUpArchivesLinkStripsSecondAccountPrefix() {
        let row: Row = [
            "id": 1,
            "channel_id": "2:C0456",
            "message_ts": "1740577800.000100",
            "sender_user_id": "2:U042",
            "trigger_type": "mention",
            "permalink": "",
            "status": "pending",
            "priority": "medium"
        ]
        XCTAssertEqual(CatchUpViewModel.slackMessageURL(for: InboxItem(row: row))?.absoluteString,
                       "https://slack.com/archives/C0456/p1740577800000100")
    }

    /// An accumulated channel item (#586) decodes every message once, and each
    /// gets its own link: its permalink, else an archives link on the item's
    /// channel; rows show the sender, the title counts the earlier ones too.
    func testAccumulatedChannelItemListsEveryMentionWithItsLink() {
        let row: Row = [
            "id": 1,
            "channel_id": "2:C0456",
            "message_ts": "1740577900.000100",
            "sender_user_id": "2:U043",
            "trigger_type": "mention",
            "mentions_earlier": 3,
            "mentions": """
            [{"ts":"1740577800.000100","sender":"2:U042","trigger":"mention","text":"first","permalink":"https://example.com/p1"},
             {"ts":"1740577900.000100","sender":"2:U043","trigger":"mention","text":"second"}]
            """
        ]
        let item = InboxItem(row: row)
        let mentions = item.mentionList
        XCTAssertEqual(mentions.map(\.text), ["first", "second"])
        XCTAssertTrue(item.isAccumulated)
        XCTAssertEqual(item.mentionCountTitle, "5 mentions")
        XCTAssertEqual(CatchUpViewModel.slackMessageURL(for: mentions[0], channelID: item.channelID)?.absoluteString,
                       "https://example.com/p1")
        XCTAssertEqual(CatchUpViewModel.slackMessageURL(for: mentions[1], channelID: item.channelID)?.absoluteString,
                       "https://slack.com/archives/C0456/p1740577900000100")
        XCTAssertEqual(InboxItemInline.mentionLine(mentions[0], senderNames: ["2:U042": "Ann"]), "Ann: first")
        XCTAssertEqual(InboxItemInline.mentionLine(mentions[1], senderNames: [:]), "second")
    }

    /// "mentions" only when every listed entry is a mention; a mix is "messages".
    func testMentionCountTitleWording() {
        let mixed = InboxItem(row: [
            "id": 1,
            "mentions": """
            [{"ts":"1","sender":"U1","trigger":"mention","text":"a"},{"ts":"2","sender":"U2","trigger":"reaction","text":"b"}]
            """
        ])
        XCTAssertEqual(mixed.mentionCountTitle, "2 messages")
    }

    /// The caption of an accumulated item names everyone who wrote — "Ann, Bob"
    /// when all resolve and there are at most three, else "N people" — like Go
    /// `db.InboxMentionSenders`.
    func testAccumulatedItemCaptionNamesEverySender() {
        let item = InboxItem(row: [
            "id": 1,
            "mentions": """
            [{"ts":"1","sender":"U1","text":"a"},{"ts":"2","sender":"U2","text":"b"},{"ts":"3","sender":"U1","text":"c"}]
            """
        ])
        XCTAssertEqual(item.mentionSendersLabel(names: ["U1": "Ann", "U2": "Bob"]), "Ann, Bob")
        XCTAssertEqual(item.mentionSendersLabel(names: ["U1": "Ann"]), "2 people")
        XCTAssertEqual(CatchUpViewModel.originCaption(sender: "Ann, Bob", channel: "eng"), "from Ann, Bob in #eng")
    }

    /// An absent column is no list; a malformed value is no list too (logged).
    func testMentionsAbsentOrMalformed() {
        XCTAssertTrue(InboxItem(row: ["id": 2, "mentions": "not json"]).mentionList.isEmpty)
        XCTAssertTrue(InboxItem(row: ["id": 3]).mentionList.isEmpty)
        XCTAssertFalse(InboxItem(row: ["id": 3]).isAccumulated)
    }

    func testWhoToPingUserLinkResolvesSecondAccountTeam() {
        let links = SlackLinkResolver(teamIDByAccount: [1: "T001", 2: "T999"], fallbackTeamID: "T001")
        XCTAssertEqual(WhoToPingView.slackUserURL("2:U042", links: links)?.absoluteString,
                       "slack://user?team=T999&id=U042")
        // Resolver not loaded yet: still no namespaced id on the wire.
        XCTAssertEqual(WhoToPingView.slackUserURL("2:U042", links: nil)?.absoluteString,
                       "slack://user?id=U042")
    }
}
