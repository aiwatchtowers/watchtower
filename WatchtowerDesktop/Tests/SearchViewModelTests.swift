import Foundation
import GRDB
import Testing
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@Suite("SearchViewModel Helpers")
@MainActor
struct SearchViewModelHelperTests {

    private func makeManager() throws -> DatabaseManager {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager
    }

    @Test("slack link fallback team populated from the workspace row")
    func workspaceTeamIDLoaded() throws {
        let manager = try makeManager()
        try manager.dbPool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO workspace (id, name) VALUES ('T1', 'test')")
        }

        let vm = SearchViewModel(dbManager: manager)
        #expect(vm.slackLinks?.fallbackTeamID == "T1")
    }

    @Test("slackChannelURL resolves a namespaced id to its own account's team")
    func slackChannelURLSecondAccount() throws {
        let manager = try makeManager()
        let second = try manager.dbPool.write { db -> Int64 in
            try TestDatabase.insertWorkspace(db, id: "T001")
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T001")
            return try TestDatabase.insertSlackAccount(db, teamID: "T999")
        }
        let vm = SearchViewModel(dbManager: manager)
        #expect(vm.slackChannelURL(channelID: "\(second):C0456")?.absoluteString
            == "slack://channel?team=T999&id=C0456")
    }

    @Test("slackChannelURL returns nil without team id")
    func slackChannelURLNoTeam() throws {
        let manager = try makeManager()
        let vm = SearchViewModel(dbManager: manager)
        #expect(vm.slackChannelURL(channelID: "C1") == nil)
    }

    @Test("slackChannelURL constructs slack:// URL when team id present")
    func slackChannelURLWithTeam() throws {
        let manager = try makeManager()
        try manager.dbPool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO workspace (id, name) VALUES ('T42', 'test')")
        }
        let vm = SearchViewModel(dbManager: manager)
        let url = vm.slackChannelURL(channelID: "C123")
        #expect(url?.absoluteString == "slack://channel?team=T42&id=C123")
    }

    @Test("Empty query clears results immediately")
    func emptyQueryClearsResults() async throws {
        let manager = try makeManager()
        let vm = SearchViewModel(dbManager: manager)
        vm.query = "   "
        vm.search()
        #expect(vm.results.isEmpty)
    }

    @Test("Whitespace-only query results in empty result list (no debounce)")
    func whitespaceOnlyQuery() async throws {
        let manager = try makeManager()
        let vm = SearchViewModel(dbManager: manager)
        vm.query = "\t\n  "
        vm.search()
        #expect(vm.results.isEmpty)
    }
}
