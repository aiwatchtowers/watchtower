import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Settings → Slack "Reaction commands" editor's VM: load, trust labels,
/// and the three GRDB writes, each followed by a reload.
@MainActor
final class ReactionDictionaryViewModelTests: XCTestCase {
    private func makePool() throws -> (DatabasePool, String) {
        try TestDatabase.createPool()
    }

    func testRefreshLoadsMappingsAndTrust() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "white_check_mark", tool: "create_target")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "bulb", tool: "create_idea")
            try TestDatabase.insertToolTrust(db, tool: "create_idea", trust: "execute")
        }
        let vm = ReactionDictionaryViewModel(dbPool: pool)

        await vm.refreshAsync()

        XCTAssertEqual(vm.mappings.map(\.emoji), ["bulb", "white_check_mark"])
        XCTAssertEqual(vm.trustFor(tool: "create_idea"), "execute", "seeded trust row")
        XCTAssertEqual(vm.trustFor(tool: "create_target"), "ask", "no tool_trust row reads as Go's default")
        XCTAssertNil(vm.error)
    }

    func testUpsertAddsAndRepointsAMapping() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        let vm = ReactionDictionaryViewModel(dbPool: pool)

        await vm.upsert(emoji: "eyes", tool: "create_track")
        XCTAssertEqual(vm.mappings.map(\.tool), ["create_track"])

        await vm.upsert(emoji: "eyes", tool: "create_idea")
        XCTAssertEqual(vm.mappings.map(\.tool), ["create_idea"], "same emoji repointed, not duplicated")
        XCTAssertNil(vm.error)
    }

    func testSetEnabledAndDeleteReloadTheList() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "eyes", tool: "create_track")
        }
        let vm = ReactionDictionaryViewModel(dbPool: pool)
        await vm.refreshAsync()

        await vm.setEnabled(emoji: "eyes", enabled: false)
        XCTAssertEqual(vm.mappings.first?.enabled, false)

        await vm.delete(emoji: "eyes")
        XCTAssertTrue(vm.mappings.isEmpty)
        XCTAssertNil(vm.error)
    }
}
