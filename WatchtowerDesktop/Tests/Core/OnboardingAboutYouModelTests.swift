import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class OnboardingAboutYouModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        try pool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", teamName: "Acme", currentUserID: "1:U_ME")
            try TestDatabase.insertUser(db, id: "1:U_ANNA", name: "anna.k", displayName: "Anna K.", realName: "Anna Kovalenko")
            try TestDatabase.insertUser(db, id: "1:U_OLEG", name: "oleg.d", displayName: "Oleg D.", realName: "Oleg Dub")
            try TestDatabase.insertUser(db, id: "1:U_OLGA", name: "olga.t", displayName: "Olga T.", realName: "Ольга Т")
            try TestDatabase.insertUser(db, id: "1:U_BOT", name: "olbot", displayName: "Ol Bot", isBot: true)
            try TestDatabase.insertUser(db, id: "1:U_GONE", name: "olaf", displayName: "Olaf", isDeleted: true)
            try TestDatabase.insertUser(db, id: "1:U_ME", name: "olena.me", displayName: "Olena (me)")
            try TestDatabase.insertUser(db, id: "1:USLACKBOT", name: "slackbot", displayName: "Slackbot")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - People

    /// No bots, deleted users, Slackbot, or the owner (the account's own
    /// user).
    func testPickablePeopleExcludeBotsDeletedSlackbotAndTheOwner() throws {
        let people = try pool.read { db in try OnboardingAboutYouModel.pickablePeople(db) }
        XCTAssertEqual(Set(people.map(\.id)), ["1:U_ANNA", "1:U_OLEG", "1:U_OLGA"])
    }

    /// Every connected account's own user is the owner, in any workspace.
    func testOwnerOfASecondAccountIsExcludedToo() throws {
        try pool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T2", teamName: "Beta", currentUserID: "2:U_ME2")
            try TestDatabase.insertUser(db, id: "2:U_ME2", name: "me2", displayName: "Me elsewhere")
            try TestDatabase.insertUser(db, id: "2:U_BOB", name: "bob", displayName: "Bob")
        }
        let people = try pool.read { db in try OnboardingAboutYouModel.pickablePeople(db) }
        XCTAssertFalse(people.contains { $0.id == "2:U_ME2" })
        XCTAssertTrue(people.contains { $0.id == "2:U_BOB" })
    }

    func testWorkspaceNamesOnlyWithSeveralAccounts() async throws {
        let model = OnboardingAboutYouModel()
        await model.load(from: pool)
        XCTAssertNil(model.workspaceName(for: "1:U_ANNA"), "one workspace needs no label")

        try await pool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T2", teamName: "Beta") }
        await model.reloadPeople(from: pool)
        XCTAssertEqual(model.workspaceName(for: "1:U_ANNA"), "Acme")
        XCTAssertEqual(model.workspaceName(for: "2:U_X"), "Beta")
        XCTAssertNil(model.workspaceName(for: "U_BARE"))
    }

    /// One person fills one role: anyone picked in any field is not offered
    /// in the others.
    func testAllPickedSpansTheThreeFields() async {
        let model = OnboardingAboutYouModel()
        await model.load(from: pool)
        model.manager = "1:U_ANNA"
        model.reports = ["1:U_OLEG"]
        XCTAssertEqual(model.allPicked, ["1:U_ANNA", "1:U_OLEG"])
        let offered = OnboardingAboutYouModel.search("o", in: model.people, excluding: model.allPicked).map(\.id)
        XCTAssertEqual(offered, ["1:U_OLGA"])
    }

    // MARK: - A profile that cannot be read

    /// Done must never write empty fields over a profile it could not read:
    /// the form is not prefilled, and a people re-read keeps the error.
    func testPrefillErrorLeavesTheAnswersNotReady() async throws {
        try await pool.write { db in
            try db.execute(sql: "DROP TABLE user_profile")
            try db.execute(sql: "CREATE TABLE user_profile (id INTEGER PRIMARY KEY)")
        }
        let model = OnboardingAboutYouModel()
        await model.load(from: pool)

        XCTAssertFalse(model.isPrefilled)
        XCTAssertNotNil(model.profileError)
        XCTAssertFalse(model.people.isEmpty, "the people still load")
        XCTAssertNil(model.peopleError)

        await model.reloadPeople(from: pool)
        XCTAssertNotNil(model.profileError, "a people re-read never clears the profile error")
        XCTAssertFalse(model.isPrefilled)
    }

    func testMissingDatabaseIsAVisibleError() {
        let model = OnboardingAboutYouModel()
        model.databaseUnavailable()
        XCTAssertNotNil(model.profileError)
        XCTAssertFalse(model.isPrefilled)
    }

    func testSearchByNameRealNameAndHandle() throws {
        let people = try pool.read { db in try OnboardingAboutYouModel.pickablePeople(db) }
        func ids(_ query: String, excluding: [String] = []) -> Set<String> {
            Set(OnboardingAboutYouModel.search(query, in: people, excluding: excluding).map(\.id))
        }
        XCTAssertEqual(ids("ol"), ["1:U_OLEG", "1:U_OLGA"], "no bot, no deleted user")
        XCTAssertEqual(ids("Kovalenko"), ["1:U_ANNA"])
        XCTAssertEqual(ids("@oleg.d"), ["1:U_OLEG"])
        XCTAssertEqual(ids("ольга"), ["1:U_OLGA"])
        XCTAssertEqual(ids("ol", excluding: ["1:U_OLEG"]), ["1:U_OLGA"], "picked people are not offered again")
        XCTAssertEqual(ids("ol", excluding: ["U_OLEG"]), ["1:U_OLGA"], "a raw id still matches its namespaced user")
        XCTAssertEqual(ids("  "), [])
        XCTAssertEqual(OnboardingAboutYouModel.search("o", in: people, excluding: [], limit: 1).count, 1)
    }

    // MARK: - Prefill

    /// The form always starts from the profile Done writes over, so an
    /// untouched field writes back exactly what was there.
    func testPrefillRoundTrips() async throws {
        let stored = OnboardingAboutYou(role: "EM, Platform", manager: "1:U_ANNA", reports: ["1:U_OLEG"], peers: ["1:U_OLGA"])
        try await pool.write { db in try OnboardingProfileWriter.done(db, about: stored) }

        let model = OnboardingAboutYouModel()
        await model.load(from: pool)

        XCTAssertTrue(model.isPrefilled)
        XCTAssertEqual(model.answers, stored)
        XCTAssertEqual(model.people.count, 3)
        try await pool.write { [answers = model.answers] db in try OnboardingProfileWriter.done(db, about: answers) }
        let reread = try await pool.read { db in try OnboardingProfileWriter.currentAnswers(db) }
        XCTAssertEqual(reread, stored)
    }

    func testNoProfileStartsEmpty() async {
        let model = OnboardingAboutYouModel()
        await model.load(from: pool)
        XCTAssertEqual(model.answers, OnboardingAboutYou())
        XCTAssertTrue(model.isPrefilled)
        XCTAssertNil(model.profileError)
        XCTAssertNil(model.peopleError)
    }

    /// Back to Connect and return keeps what was typed; a setup re-run
    /// prefills again.
    func testPrefillOncePerRun() async throws {
        let model = OnboardingAboutYouModel()
        await model.load(from: pool)
        model.role = "typed"
        await model.load(from: pool)
        XCTAssertEqual(model.role, "typed")

        try await pool.write { db in try OnboardingProfileWriter.done(db, about: OnboardingAboutYou(role: "saved")) }
        model.prepareForRerun()
        await model.load(from: pool)
        XCTAssertEqual(model.role, "saved")
    }

    func testAnswersTrimTheManagerAndDropEmptyIDs() {
        let model = OnboardingAboutYouModel()
        model.role = "EM"
        model.manager = "  1:U_ANNA \n"
        model.reports = ["1:U_OLEG", "", "  "]
        model.peers = [" ", "1:U_OLGA"]
        XCTAssertEqual(model.answers, OnboardingAboutYou(role: "EM", manager: "1:U_ANNA", reports: ["1:U_OLEG"], peers: ["1:U_OLGA"]))
    }

    func testPeopleReloadPicksUpUsersSavedMeanwhile() async throws {
        let model = OnboardingAboutYouModel()
        await model.load(from: pool)
        try await pool.write { db in try TestDatabase.insertUser(db, id: "1:U_NEW", name: "new", displayName: "New") }
        await model.reloadPeople(from: pool)
        XCTAssertTrue(model.people.contains { $0.id == "1:U_NEW" })
    }

    func testStillLoadingText() {
        XCTAssertEqual(PeopleRosterState.loading(fetched: 412, saved: 0).stillLoadingText, "Still loading people — 412")
        XCTAssertEqual(PeopleRosterState.loading(fetched: 600, saved: 412).stillLoadingText, "Still loading people — 412 of 600")
        XCTAssertNil(PeopleRosterState.done(count: 600).stillLoadingText)
    }

    /// With no owner yet, currentAnswers reads the same row done writes.
    func testNoOwnerPrefillReadsTheRowDoneWrites() async throws {
        let (bare, barePath) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: barePath) }
        let owner = try await bare.read { db in try OwnerQueries.resolve(db) }
        XCTAssertFalse(owner.isKnown)

        let stored = OnboardingAboutYou(role: "Founder", manager: "", reports: ["1:U_A"], peers: ["1:U_B"])
        try await bare.write { db in try OnboardingProfileWriter.done(db, about: stored) }
        let read = try await bare.read { db in try OnboardingProfileWriter.currentAnswers(db) }
        XCTAssertEqual(read, stored)
    }
}
