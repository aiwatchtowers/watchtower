import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// OWNER-01 for People: the "me" card and the social graph are keyed by the
/// owner's Slack user id, never by the profile row's key (which may be a
/// Google/Jira owner id or a row parked under an earlier key).
final class PeopleViewModelOwnerTests: XCTestCase {
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

    private static func insertInteraction(_ db: Database, userA: String) throws {
        try db.execute(sql: """
            INSERT INTO user_interactions (user_a, user_b, period_from, period_to, interaction_score)
            VALUES (?, 'U002', 100, 200, 1)
            """, arguments: [userA])
    }

    /// A Google-only owner has no Slack identity: no "me" card and no social
    /// graph, even though the profile row is keyed by the owner id.
    @MainActor
    func testOwner01GoogleOwnerHasNoSlackGraph() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
            try TestDatabase.insertProfile(db, slackUserID: "google:me@x.com", role: "EM")
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200)
            try Self.insertInteraction(db, userA: "google:me@x.com")
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.currentProfile?.role, "EM")
        XCTAssertNil(vm.currentUserID, "the profile key is not a Slack user id")
        XCTAssertTrue(vm.interactions.isEmpty)
    }

    /// A Slack owner whose profile is still parked under another key gets the
    /// graph for its Slack user id, not for the profile row's key.
    @MainActor
    func testOwner01GraphUsesOwnerSlackIDNotProfileKey() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", currentUserID: "1:U001")
            try TestDatabase.insertProfile(db, slackUserID: "pending:owner", role: "EM")
            try TestDatabase.insertPeopleCard(db, userID: "1:U001", periodFrom: 100, periodTo: 200)
            try Self.insertInteraction(db, userA: "1:U001")
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.currentProfile?.role, "EM")
        XCTAssertEqual(vm.currentUserID, "1:U001")
        XCTAssertEqual(vm.interactions.count, 1)
        XCTAssertEqual(vm.myCard?.userID, "1:U001")
    }

    // MARK: - Profile writes

    /// Stars a person and saves connections through the VM, then re-reads
    /// the table: one row, keyed `wantKey`, carrying both writes. With
    /// `reloads`, a fresh `load()` must read the star back (an unknown owner
    /// has no readable profile, so its parked row is checked in the table only).
    @MainActor
    private func assertProfileWritesPersist(
        under wantKey: String, reloads: Bool = true, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()
        vm.toggleStarredPerson("U002")
        vm.updateConnections(reports: ["U003"], peers: [], manager: "U004")
        XCTAssertNil(vm.errorMessage, file: file, line: line)

        let rows = try dbManager.dbPool.read { try UserProfile.fetchAll($0, sql: "SELECT * FROM user_profile") }
        XCTAssertEqual(rows.map(\.slackUserID), [wantKey], "exactly one profile row, keyed to the owner", file: file, line: line)
        XCTAssertEqual(rows.first?.decodedStarredPeople, ["U002"], file: file, line: line)
        XCTAssertEqual(rows.first?.reports, #"["U003"]"#, file: file, line: line)
        XCTAssertEqual(rows.first?.manager, "U004", file: file, line: line)

        guard reloads else { return }
        vm.load()
        XCTAssertEqual(vm.starredPeopleIDs, ["U002"], "the star survives a reload", file: file, line: line)
    }

    /// A Slack owner whose profile is parked under `pending:owner`: the
    /// writes re-key that row onto the owner id and land on it.
    @MainActor
    func testOwner01SlackOwnerProfileWritesReKeyParkedRow() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", currentUserID: "1:U001")
            try TestDatabase.insertProfile(db, slackUserID: ProfileQueries.pendingOwnerKey, role: "EM")
        }
        try assertProfileWritesPersist(under: "1:U001")
    }

    /// A Google-only owner has no Slack id, yet its profile writes land.
    @MainActor
    func testOwner01GoogleOwnerProfileWritesPersist() throws {
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
            try TestDatabase.insertProfile(db, slackUserID: "google:me@x.com", role: "EM")
        }
        try assertProfileWritesPersist(under: "google:me@x.com")
    }

    /// No owner and no profile yet: the writes park on the pending key
    /// (the onboarding rule) instead of silently hitting zero rows.
    @MainActor
    func testOwner01NoOwnerProfileWritesParkOnPendingKey() throws {
        try assertProfileWritesPersist(under: ProfileQueries.pendingOwnerKey, reloads: false)
    }
}
