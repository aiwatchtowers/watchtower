import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// OWNER-01 on the onboarding profile writes: the owner comes from
/// `OwnerQueries.resolve`, so a Google-only install writes a real profile row,
/// and no owner at all parks the answers under the pending key instead of
/// dead-ending onboarding.
final class OnboardingChatViewModelOwnerTests: XCTestCase {
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

    /// A Google-only install has an owner (`google:<lower-cased email>`), so
    /// the extracted context lands in a profile row keyed by it.
    @MainActor
    func testOwner01SaveProfileWithContextGoogleOnly() async throws {
        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
        }
        let mock = MockClaudeService(events: [.text("Context about the user."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        await vm.generatePromptContext()

        XCTAssertNil(vm.errorMessage)
        let profile = try await dbManager.dbPool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: "google:me@x.com")
        }
        XCTAssertEqual(profile?.customPromptContext, "Context about the user.")
    }

    /// No connected account: onboarding must never dead-end. The extracted
    /// profile parks under `ProfileQueries.pendingOwnerKey` with no error, so
    /// the team-form step advances exactly as it does with a known owner.
    @MainActor
    func testOwner01SaveProfileWithContextNoOwnerParksUnderPendingKey() async throws {
        let mock = MockClaudeService(events: [.text("Context about the user."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)
        vm.role = "EM"
        vm.team = "Core"

        await vm.generatePromptContext()

        XCTAssertNil(vm.errorMessage, "a nil errorMessage is what advances the team-form step")
        let rows = try await dbManager.dbPool.read { db in
            try UserProfile.fetchAll(db, sql: "SELECT * FROM user_profile")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.slackUserID, "pending:owner")
        XCTAssertEqual(rows.first?.role, "EM")
        XCTAssertEqual(rows.first?.team, "Core")
        XCTAssertEqual(rows.first?.customPromptContext, "Context about the user.")
    }

    /// The parked profile survives the owner arriving later: a Google account
    /// is connected, the owner read falls back to the parked row, and the
    /// first owner write re-keys that one row to `google:…`.
    @MainActor
    func testOwner01PendingProfileAdoptedByLaterOwner() async throws {
        let mock = MockClaudeService(events: [.text("Context about the user."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)
        vm.role = "EM"
        await vm.generatePromptContext()
        XCTAssertNil(vm.errorMessage)

        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
        }
        let adopted = try await dbManager.dbPool.read { db in
            try ProfileQueries.fetchOwnerProfile(db, owner: OwnerQueries.resolve(db))
        }
        XCTAssertEqual(adopted?.role, "EM")
        XCTAssertEqual(adopted?.customPromptContext, "Context about the user.")

        let unwrapped = try XCTUnwrap(adopted)
        try await dbManager.dbPool.write { db in
            try ProfileQueries.upsertOwnerProfile(db, owner: OwnerQueries.resolve(db), profile: unwrapped)
        }
        let rows = try await dbManager.dbPool.read { db in
            try UserProfile.fetchAll(db, sql: "SELECT * FROM user_profile")
        }
        XCTAssertEqual(rows.count, 1, "the parked row is re-keyed, never duplicated")
        XCTAssertEqual(rows.first?.slackUserID, "google:me@x.com")
        XCTAssertEqual(rows.first?.role, "EM")
    }

    /// No owner: the completion flag lands on the parked row, so once an
    /// owner appears the owner's profile says onboarding is done (the Desktop
    /// re-checks it after a UserDefaults reset; `watchtower profile` prints it).
    @MainActor
    func testOwner01MarkOnboardingDoneNoOwnerFlagsPendingRow() async throws {
        let mock = MockClaudeService(events: [.text("Context about the user."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)
        await vm.generatePromptContext()
        let done = await vm.markOnboardingDone()
        XCTAssertTrue(done)
        XCTAssertNil(vm.errorMessage)

        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
        }
        let (profile, count) = try await dbManager.dbPool.read { db in
            (try ProfileQueries.fetchCurrentProfile(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_profile"))
        }
        XCTAssertEqual(profile?.onboardingDone, true)
        XCTAssertEqual(profile?.customPromptContext, "Context about the user.")
        XCTAssertEqual(count, 1)
    }

    /// No current owner but an older profile row exists (e.g. keyed by a
    /// since-removed Slack #1): the onboarding save updates that one row
    /// rather than adding a pending row an exact-key match could later beat.
    @MainActor
    func testOwner01SaveProfileWithContextNoOwnerReusesExistingRow() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertProfile(db, slackUserID: "1:U_OLD", role: "Old")
        }
        let mock = MockClaudeService(events: [.text("Context about the user."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)
        vm.role = "EM"

        await vm.generatePromptContext()

        XCTAssertNil(vm.errorMessage)
        let rows = try await dbManager.dbPool.read { db in
            try UserProfile.fetchAll(db, sql: "SELECT * FROM user_profile")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.slackUserID, "1:U_OLD")
        XCTAssertEqual(rows.first?.role, "EM")
        XCTAssertEqual(rows.first?.customPromptContext, "Context about the user.")
    }

    @MainActor
    func testOwner01MarkOnboardingDoneGoogleOnlyWritesFlag() async throws {
        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
        }
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        let done = await vm.markOnboardingDone()

        XCTAssertTrue(done)
        XCTAssertNil(vm.errorMessage)
        let profile = try await dbManager.dbPool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: "google:me@x.com")
        }
        XCTAssertEqual(profile?.onboardingDone, true)
    }
}
