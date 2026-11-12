import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class FeedbackButtonsViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeView() throws -> (FeedbackButtons, DatabaseManager, String) {
        let (db, path) = try TestDatabase.createDatabaseManager()
        let view = FeedbackButtons(
            entityType: "digest",
            entityID: "42",
            dbManager: db
        )
        return (view, db, path)
    }

    /// Waits for the feedback row that the Task inside submitFeedback writes,
    /// on the database's own change signal (a ValueObservation) — no deadline.
    private func waitForFeedback(_ db: DatabaseManager, entityID: String) async throws -> Feedback? {
        let observation = ValueObservation.tracking { db in
            try FeedbackQueries.getFeedback(db, entityType: "digest", entityID: entityID)
        }
        for try await fb in observation.values(in: db.dbPool) where fb != nil {
            return fb
        }
        return nil
    }

    // MARK: - Tests

    /// Рендерятся обе кнопки и у них правильные подсказки.
    func testBothButtonsPresent() throws {
        let (view, _, path) = try makeView()
        defer { TestDatabase.cleanup(path: path) }

        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 2, "Expected thumbs up + thumbs down")

        let helps = try buttons.map { try $0.help().string() }
        XCTAssertTrue(helps.contains("Good result"))
        XCTAssertTrue(helps.contains("Bad result"))
    }

    /// Тап «Good result» (thumbs up) → запись в БД с rating=+1.
    func testTapThumbsUpWritesPositiveFeedback() async throws {
        let (view, db, path) = try makeView()
        defer { TestDatabase.cleanup(path: path) }

        let upButton = try view.inspect().find(button: "Good result")
        try upButton.tap()

        let fb = try await waitForFeedback(db, entityID: "42")
        XCTAssertNotNil(fb, "Feedback row must be persisted after tap")
        XCTAssertEqual(fb?.rating, 1)
    }

    /// Тап «Bad result» (thumbs down) → запись в БД с rating=-1.
    func testTapThumbsDownWritesNegativeFeedback() async throws {
        let (view, db, path) = try makeView()
        defer { TestDatabase.cleanup(path: path) }

        let downButton = try view.inspect().find(button: "Bad result")
        try downButton.tap()

        let fb = try await waitForFeedback(db, entityID: "42")
        XCTAssertNotNil(fb)
        XCTAssertEqual(fb?.rating, -1)
    }
}
