import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A briefing item's Make a Task (R9): a target from the item's prefill,
/// opened in Targets; a cut title keeps the item's whole text in the intent.
@MainActor
final class AppStateMakeTaskTests: XCTestCase {
    private var path: String!
    private var appState: AppState!

    override func setUp() async throws {
        let (manager, dbPath) = try TestDatabase.createDatabaseManager()
        path = dbPath
        appState = AppState.isolated()
        appState.databaseManager = manager
    }

    override func tearDown() async throws {
        appState = nil
        TestDatabase.cleanup(path: path)
    }

    private func briefing(attention: String = "[]", coaching: String = "[]") throws -> Briefing {
        let pool = try XCTUnwrap(appState.databaseManager).dbPool
        return try XCTUnwrap(try pool.write { db -> Briefing? in
            try TestDatabase.insertBriefing(db, date: "2026-10-22", attention: attention, coaching: coaching)
            return try BriefingQueries.fetchByDate(db, date: "2026-10-22")
        })
    }

    private func insertTrack(text: String, context: String) throws -> Track {
        let pool = try XCTUnwrap(appState.databaseManager).dbPool
        return try XCTUnwrap(try pool.write { db -> Track? in
            let id = try TestDatabase.insertTrack(db, text: text, context: context, channelIDs: #"["C001"]"#)
            return try TrackQueries.fetchByID(db, id: Int(id))
        })
    }

    private func target(_ id: Int) throws -> Target {
        let pool = try XCTUnwrap(appState.databaseManager).dbPool
        return try XCTUnwrap(try pool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    func testCoachingItemMakesABriefingSourcedTaskAndOpensIt() async throws {
        let shown = try briefing(coaching: #"[{"text":"Ask for review early","category":"process"}]"#)
        let item = try XCTUnwrap(shown.parsedCoaching.first)

        let failure = await appState.makeTask(from: .coaching(item), briefing: shown)

        XCTAssertNil(failure)
        let id = try XCTUnwrap(appState.pendingTargetID)
        XCTAssertEqual(appState.selectedDestination, .targets)
        let made = try target(id)
        XCTAssertEqual(made.text, "Ask for review early")
        XCTAssertEqual(made.intent, "Surfaced in briefing on 2026-10-22.")
        XCTAssertEqual(made.sourceType, "briefing")
        XCTAssertEqual(made.sourceID, String(shown.id))
    }

    func testACutTitleKeepsTheWholeTextInTheIntent() async throws {
        let long = String(repeating: "follow up on the release checklist ", count: 6)
            .trimmingCharacters(in: .whitespaces)
        let shown = try briefing(attention: #"[{"text":"\#(long)","priority":"high","suggest_target":true}]"#)
        let item = try XCTUnwrap(shown.parsedAttention.first)

        let failure = await appState.makeTask(from: .attention(item), briefing: shown)

        XCTAssertNil(failure)
        let made = try target(try XCTUnwrap(appState.pendingTargetID))
        XCTAssertEqual(made.text, TargetComposerLogic.deriveTitle(from: long))
        XCTAssertNotEqual(made.text, long, "the fixture's title is cut")
        XCTAssertTrue(made.intent.hasPrefix(long + "\n\nSurfaced in briefing on 2026-10-22."), made.intent)
        XCTAssertEqual(made.sourceType, "briefing")
    }

    func testATrackMakesATrackSourcedTaskWithItsChannelLinkAndOpensIt() async throws {
        let pool = try XCTUnwrap(appState.databaseManager).dbPool
        let track = try insertTrack(text: "Ship the release notes", context: "Agreed in standup")

        let failure = await appState.makeTask(fromTrack: track)

        XCTAssertNil(failure)
        let id = try XCTUnwrap(appState.pendingTargetID)
        XCTAssertEqual(appState.selectedDestination, .targets)
        let made = try target(id)
        XCTAssertEqual(made.text, "Ship the release notes")
        XCTAssertTrue(made.intent.hasPrefix("Agreed in standup"), made.intent)
        XCTAssertEqual(made.sourceType, "track")
        XCTAssertEqual(made.sourceID, String(track.id))
        XCTAssertEqual(made.periodStart, made.periodEnd)
        let links = try await pool.read { db in try TargetQueries.fetchLinks(db, targetID: id) }
        XCTAssertEqual(links.map(\.externalRef), ["slack:C001"])
    }
}
