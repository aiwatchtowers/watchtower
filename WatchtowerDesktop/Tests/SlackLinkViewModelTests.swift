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

    @MainActor
    func testWorkspaceOverviewViewModelResolvesSecondAccountTeam() async throws {
        let second = try seed(Self.seedTwoAccounts)

        let vm = WorkspaceOverviewViewModel(dbManager: dbManager)
        await vm.load()

        XCTAssertEqual(vm.slackChannelURL(channelID: "\(second):C0456")?.absoluteString,
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

    func testWhoToPingUserLinkResolvesSecondAccountTeam() {
        let links = SlackLinkResolver(teamIDByAccount: [1: "T001", 2: "T999"], fallbackTeamID: "T001")
        XCTAssertEqual(WhoToPingView.slackUserURL("2:U042", links: links)?.absoluteString,
                       "slack://user?team=T999&id=U042")
        // Resolver not loaded yet: still no namespaced id on the wire.
        XCTAssertEqual(WhoToPingView.slackUserURL("2:U042", links: nil)?.absoluteString,
                       "slack://user?id=U042")
    }
}
