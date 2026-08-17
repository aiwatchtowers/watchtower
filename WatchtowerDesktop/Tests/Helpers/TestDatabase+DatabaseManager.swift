import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// `DatabaseManager` stays app-side (Sources/Database/DatabaseManager.swift — it
/// depends on the app-side `ChatMessageQueries`), so this wrapper around
/// `TestDatabase.createPool()` can't live in the `WatchtowerTestSupport` library
/// target alongside the rest of `TestDatabase`. Kept here so the many app-side
/// ViewModel tests that need a real `DatabaseManager` don't have to change.
extension TestDatabase {
    /// Create a file-based DatabaseManager for ViewModel tests (DatabasePool requires a file).
    static func createDatabaseManager() throws -> (DatabaseManager, String) {
        let (pool, path) = try createPool()
        return (DatabaseManager(pool: pool), path)
    }
}
