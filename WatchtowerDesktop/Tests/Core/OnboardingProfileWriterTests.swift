import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Onboarding's About-you writes (no LLM). The OWNER-01 owner/no-owner
/// cases live in `OnboardingProfileWriterOwnerTests`.
final class OnboardingProfileWriterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        try pool.write { db in
            let id = try TestDatabase.insertSlackAccount(db, teamID: "T1", teamName: "Acme", currentUserID: "1:U_ME")
            XCTAssertEqual(id, 1)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func profile() throws -> UserProfile? {
        try pool.read { db in try ProfileQueries.fetchCurrentProfile(db) }
    }

    func testDoneWritesRoleAndEveryPerson() throws {
        let about = OnboardingAboutYou(
            role: "EM, Core platform", manager: "1:U_MGR", reports: ["1:U_R1", "1:U_R2"], peers: ["1:U_PEER"]
        )
        try pool.write { db in try OnboardingProfileWriter.done(db, about: about) }

        let saved = try XCTUnwrap(try profile())
        XCTAssertEqual(saved.slackUserID, "1:U_ME")
        XCTAssertEqual(saved.role, "EM, Core platform")
        XCTAssertEqual(saved.manager, "1:U_MGR")
        XCTAssertEqual(saved.reports, #"["1:U_R1","1:U_R2"]"#)
        XCTAssertEqual(saved.peers, #"["1:U_PEER"]"#)
        XCTAssertTrue(saved.onboardingDone)
    }

    func testLaterSetsTheFlagWithoutPeople() throws {
        try pool.write { db in try OnboardingProfileWriter.later(db) }

        let saved = try XCTUnwrap(try profile())
        XCTAssertTrue(saved.onboardingDone)
        XCTAssertEqual(saved.role, "")
        XCTAssertEqual(saved.manager, "")
        XCTAssertEqual(saved.reports, "[]")
        XCTAssertEqual(saved.peers, "[]")
    }

    func testLaterKeepsAnEarlierRunsAnswers() throws {
        try pool.write { db in
            try TestDatabase.insertProfile(db, slackUserID: "1:U_ME", role: "EM", peers: #"["1:U_PEER"]"#, manager: "1:U_MGR")
            try OnboardingProfileWriter.later(db)
        }

        let saved = try XCTUnwrap(try profile())
        XCTAssertTrue(saved.onboardingDone)
        XCTAssertEqual(saved.role, "EM")
        XCTAssertEqual(saved.manager, "1:U_MGR")
        XCTAssertEqual(saved.peers, #"["1:U_PEER"]"#)
    }

    /// Done writes the people exactly as given — empty included: the About
    /// you form is prefilled from the profile, so a field cleared there is a
    /// real clear, not "keep what was there".
    func testDoneOverwritesPeopleWithExactlyWhatItIsGivenEmptyIncluded() throws {
        try pool.write { db in
            try TestDatabase.insertProfile(
                db, slackUserID: "1:U_ME", reports: #"["1:U_R1"]"#, peers: #"["1:U_PEER"]"#, manager: "1:U_MGR"
            )
            try OnboardingProfileWriter.done(db, about: OnboardingAboutYou(role: "EM", reports: ["1:U_R2"]))
        }

        let saved = try XCTUnwrap(try profile())
        XCTAssertEqual(saved.manager, "")
        XCTAssertEqual(saved.reports, #"["1:U_R2"]"#)
        XCTAssertEqual(saved.peers, "[]")
    }

    func testEmptyRoleKeepsTheExistingOne() throws {
        try pool.write { db in
            try TestDatabase.insertProfile(db, slackUserID: "1:U_ME", role: "EM")
            try OnboardingProfileWriter.done(db, about: OnboardingAboutYou(role: "  \n", manager: "1:U_MGR"))
        }

        let saved = try XCTUnwrap(try profile())
        XCTAssertEqual(saved.role, "EM")
        XCTAssertEqual(saved.manager, "1:U_MGR")
    }

    func testCustomPromptContextAndOtherColumnsAreNeverTouched() throws {
        try pool.write { db in
            try TestDatabase.insertProfile(
                db, slackUserID: "1:U_ME", team: "Core", starredChannels: #"["1:C1"]"#,
                customPromptContext: "Context from an earlier onboarding."
            )
            try OnboardingProfileWriter.done(db, about: OnboardingAboutYou(role: "EM", peers: ["1:U_PEER"]))
        }

        let saved = try XCTUnwrap(try profile())
        XCTAssertEqual(saved.customPromptContext, "Context from an earlier onboarding.")
        XCTAssertEqual(saved.team, "Core")
        XCTAssertEqual(saved.starredChannels, #"["1:C1"]"#)
        let count = try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_profile") }
        XCTAssertEqual(count, 1)
    }
}

/// `later()` before any account exists, then the owner arriving — without
/// the Slack owner the main suite seeds.
final class OnboardingProfileWriterNoOwnerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    func testLaterOnAnEmptyTableParksOnePendingRowThatALaterOwnerAdopts() throws {
        try pool.write { db in try OnboardingProfileWriter.later(db) }

        let parked = try pool.read { db in try UserProfile.fetchAll(db, sql: "SELECT * FROM user_profile") }
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked.first?.slackUserID, ProfileQueries.pendingOwnerKey)
        XCTAssertEqual(parked.first?.onboardingDone, true)

        try pool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
            let owner = try OwnerQueries.resolve(db)
            let adopted = try XCTUnwrap(try ProfileQueries.fetchOwnerProfile(db, owner: owner))
            try ProfileQueries.upsertOwnerProfile(db, owner: owner, profile: adopted)
        }
        let rows = try pool.read { db in try UserProfile.fetchAll(db, sql: "SELECT * FROM user_profile") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.slackUserID, "google:me@x.com")
        XCTAssertEqual(rows.first?.onboardingDone, true)
    }
}
