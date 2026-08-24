import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class TargetChatLabelsContextTests: XCTestCase {

    func testLabelsInUseBlockPresentWhenLabelsExistAbsentOtherwise() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in
            _ = try TargetQueries.create(db, text: "untagged", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }

        // No labels anywhere → empty block, byte-identical prompt.
        let empty = TargetChatViewModel.labelsInUseBlock(dbPool: manager.dbPool)
        XCTAssertTrue(empty.isEmpty, "no labels → no block")

        try manager.dbPool.write { db in
            let a = try TargetQueries.create(db, text: "a", periodStart: "2026-06-01", periodEnd: "2026-06-30")
            _ = try TargetQueries.addTag(db, id: a, tag: "ops")
            let b = try TargetQueries.create(db, text: "b", periodStart: "2026-06-01", periodEnd: "2026-06-30")
            _ = try TargetQueries.addTag(db, id: b, tag: "infra")
        }

        let block = TargetChatViewModel.labelsInUseBlock(dbPool: manager.dbPool)
        XCTAssertTrue(block.contains("LABELS IN USE"))
        XCTAssertTrue(block.contains("ops"))
        XCTAssertTrue(block.contains("infra"))
    }

    func testSystemPromptCarriesTaskLabelsLine() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db -> Int in
            let id = try TargetQueries.create(db, text: "goal", periodStart: "2026-06-01", periodEnd: "2026-06-30")
            _ = try TargetQueries.addTag(db, id: id, tag: "ops")
            return id
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })

        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: manager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil
        )

        XCTAssertTrue(prompt.contains("Labels: ops"))
        XCTAssertTrue(prompt.contains("=== LABELS IN USE ==="))
    }

    func testSystemPromptShowsNoneForUnlabeledTask() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })

        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: manager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil
        )

        XCTAssertTrue(prompt.contains("Labels: (none)"))
        XCTAssertFalse(prompt.contains("=== LABELS IN USE ==="), "empty vocabulary → block omitted")
    }
}
