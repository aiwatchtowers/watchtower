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
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - People

    func testPickablePeopleExcludeBotsAndDeletedUsers() throws {
        let people = try pool.read { db in try OnboardingAboutYouModel.pickablePeople(db) }
        XCTAssertEqual(Set(people.map(\.id)), ["1:U_ANNA", "1:U_OLEG", "1:U_OLGA"])
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
        XCTAssertNil(model.loadError)
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
}
