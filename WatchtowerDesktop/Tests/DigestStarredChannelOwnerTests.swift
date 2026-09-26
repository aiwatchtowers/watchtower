import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// OWNER-01 for channel stars: `toggleStarredChannel` writes through
/// `ProfileQueries.ownerProfileWriteKey`, resolved inside the write — never a
/// profile key remembered at `load()`, which a later re-key can move.
final class DigestStarredChannelOwnerTests: XCTestCase {
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

    private func profileRows() throws -> [UserProfile] {
        try dbManager.dbPool.read { try UserProfile.fetchAll($0, sql: "SELECT * FROM user_profile") }
    }

    /// A Slack owner whose profile is parked under `pending:owner`, re-keyed
    /// by another writer after the Digests screen loaded: the star still
    /// lands on the one owner-keyed row and survives a reload.
    @MainActor
    func testOwner01ChannelStarPersistsForParkedSlackOwnerProfile() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", currentUserID: "1:U001")
            try TestDatabase.insertProfile(db, slackUserID: ProfileQueries.pendingOwnerKey, role: "EM")
        }
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        // Another writer (People, Profile settings, onboarding, Go) re-keys
        // the parked row after load().
        try dbManager.dbPool.write { db in
            let owner = try OwnerQueries.resolve(db)
            let profile = try XCTUnwrap(ProfileQueries.fetchOwnerProfile(db, owner: owner))
            try ProfileQueries.upsertOwnerProfile(db, owner: owner, profile: profile)
        }

        vm.toggleStarredChannel("1:C1")

        XCTAssertNil(vm.errorMessage)
        let rows = try profileRows()
        XCTAssertEqual(rows.map(\.slackUserID), ["1:U001"])
        XCTAssertEqual(rows.first?.decodedStarredChannels, ["1:C1"])
        vm.load()
        XCTAssertTrue(vm.isChannelStarred("1:C1"), "the star survives a reload")
    }

    /// A Google-only owner with no profile row yet: the star creates the
    /// owner-keyed row instead of silently doing nothing.
    @MainActor
    func testOwner01ChannelStarPersistsForGoogleOnlyOwner() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
        }
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        vm.toggleStarredChannel("1:C1")

        XCTAssertNil(vm.errorMessage)
        let rows = try profileRows()
        XCTAssertEqual(rows.map(\.slackUserID), ["google:me@x.com"])
        XCTAssertEqual(rows.first?.decodedStarredChannels, ["1:C1"])
        vm.load()
        XCTAssertTrue(vm.isChannelStarred("1:C1"), "the star survives a reload")
    }
}
