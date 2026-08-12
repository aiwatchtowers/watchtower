import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop

final class SecretaryProfileQueriesTests: XCTestCase {
    func test_fetch_emptyByDefault_and_saveRoundTrip() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try manager.dbPool.write { db in
            // No workspace row yet — fetch must return "" rather than throw.
            XCTAssertEqual(try SecretaryProfileQueries.fetch(db), "")

            try TestDatabase.insertWorkspace(db)
            try SecretaryProfileQueries.save(db, text: "I own direction X")
            XCTAssertEqual(try SecretaryProfileQueries.fetch(db), "I own direction X")
        }
    }

    func test_save_withoutWorkspaceRow_isSilentNoOp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try manager.dbPool.write { db in
            // UPDATE against zero rows succeeds without error (SQLite semantics);
            // there is nothing to persist to, so a later fetch still returns "".
            try SecretaryProfileQueries.save(db, text: "no workspace yet")
            XCTAssertEqual(try SecretaryProfileQueries.fetch(db), "")
        }
    }
}
