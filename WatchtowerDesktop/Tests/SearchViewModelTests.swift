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

@Suite("SearchViewModel guide hits")
@MainActor
struct SearchViewModelGuideTests {
    private func makeVM() async throws -> SearchViewModel {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO kb_documents (id, source, title, chunk_count)
                VALUES ('guide:features/inbox.md', 'guide', 'Inbox', 1)
                """)
            try db.execute(sql: """
                INSERT INTO kb_chunks (doc_id, idx, title, body, anchor)
                VALUES ('guide:features/inbox.md', 0, 'Inbox', 'Why use it\nThe inbox gathers items.', 'why-use-it')
                """)
        }
        return SearchViewModel(dbManager: manager)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("guideHits follow the query and clear on an empty one")
    func guideHitsFollowQuery() async throws {
        let vm = try await makeVM()
        vm.query = "inbox"
        vm.search()
        await waitUntil { !vm.guideHits.isEmpty }
        #expect(!vm.guideHits.isEmpty)
        vm.query = ""
        vm.search()
        #expect(vm.guideHits.isEmpty)
    }

    @Test("clearing the query while a search is in flight leaves nothing stale")
    func clearedQueryDuringSearch() async throws {
        let vm = try await makeVM()
        vm.query = "inbox"
        vm.search()
        try await Task.sleep(for: .milliseconds(310)) // past the debounce, reads in flight
        vm.query = ""
        vm.search()
        try await Task.sleep(for: .milliseconds(600))
        #expect(vm.guideHits.isEmpty)
        #expect(vm.results.isEmpty)
        #expect(!vm.isSearching)
    }

    @Test("FTS-hostile queries neither throw nor crash")
    func hostileQueries() async throws {
        let vm = try await makeVM()
        for q in ["\"", "*", "-", "AND", "\"inbox", "inbox -*"] {
            vm.query = q
            vm.search()
            await waitUntil { !vm.isSearching && vm.query == q }
            try await Task.sleep(for: .milliseconds(400))
            #expect(vm.errorMessage == nil)
        }
    }

    @Test("prefill keeps an existing draft")
    func prefillMerge() {
        #expect(HelpChatPrefill.merge(draft: "", prefill: "q") == "q")
        #expect(HelpChatPrefill.merge(draft: "  ", prefill: "q") == "q")
        #expect(HelpChatPrefill.merge(draft: "q", prefill: "q") == "q")
        #expect(HelpChatPrefill.merge(draft: "mine", prefill: "q") == "mine\nq")
    }
}
