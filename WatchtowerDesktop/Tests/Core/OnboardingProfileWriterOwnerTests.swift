import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// OWNER-01 on the onboarding profile writes: the owner comes from
/// `OwnerQueries.resolve`, so a Google-only install writes a real profile row,
/// and no owner at all parks the answers under the pending key instead of
/// dead-ending onboarding. The same cases as
/// `OnboardingChatViewModelOwnerTests`, moved to `OnboardingProfileWriter`
/// (owner-approved 2026-10-02). The three save cases that checked the
/// LLM-written `custom_prompt_context` (GoogleOnly, NoOwnerParksUnderPendingKey,
/// PendingProfileAdoptedByLaterOwner) are pending an owner decision and stay
/// covered by the old file meanwhile.
final class OnboardingProfileWriterOwnerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// No owner: the completion flag lands on the parked row, so once an
    /// owner appears the owner's profile says onboarding is done (the Desktop
    /// re-checks it after a UserDefaults reset; `watchtower profile` prints it).
    func testOwner01MarkOnboardingDoneNoOwnerFlagsPendingRow() throws {
        // The parked row an earlier (pre-v2) onboarding left behind.
        try pool.write { db in
            try TestDatabase.insertProfile(
                db, slackUserID: ProfileQueries.pendingOwnerKey, customPromptContext: "Context about the user."
            )
        }
        XCTAssertNoThrow(try pool.write { db in try OnboardingProfileWriter.later(db) })
        let parked = try pool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: ProfileQueries.pendingOwnerKey)
        }
        XCTAssertEqual(parked?.onboardingDone, true, "the flag lands on the parked row before any owner exists")

        try pool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
        }
        let (profile, count) = try pool.read { db in
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
    func testOwner01SaveProfileWithContextNoOwnerReusesExistingRow() throws {
        try pool.write { db in
            try TestDatabase.insertProfile(
                db, slackUserID: "1:U_OLD", role: "Old", customPromptContext: "Context about the user."
            )
        }

        XCTAssertNoThrow(try pool.write { db in
            try OnboardingProfileWriter.done(db, about: OnboardingAboutYou(role: "EM"))
        })

        let rows = try pool.read { db in
            try UserProfile.fetchAll(db, sql: "SELECT * FROM user_profile")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.slackUserID, "1:U_OLD")
        XCTAssertEqual(rows.first?.role, "EM")
        XCTAssertEqual(rows.first?.customPromptContext, "Context about the user.")
    }

    func testOwner01MarkOnboardingDoneGoogleOnlyWritesFlag() throws {
        try pool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
        }

        XCTAssertNoThrow(try pool.write { db in try OnboardingProfileWriter.later(db) })

        let (profile, count) = try pool.read { db in
            (try ProfileQueries.fetchProfile(db, slackUserID: "google:me@x.com"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_profile"))
        }
        XCTAssertEqual(profile?.onboardingDone, true)
        XCTAssertEqual(count, 1, "no pending row beside the owner's")
    }
}
