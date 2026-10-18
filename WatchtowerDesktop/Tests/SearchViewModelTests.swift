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

    /// Runs one search to completion: no fixed sleeps, the test awaits the
    /// view model's own task (debounce included).
    private func searchAndWait(_ vm: SearchViewModel, _ query: String) async {
        vm.query = query
        vm.search()
        await vm.searchTask?.value
    }

    @Test("guideHits follow the query and clear on an empty one")
    func guideHitsFollowQuery() async throws {
        let vm = try await makeVM()
        await searchAndWait(vm, "inbox")
        #expect(!vm.guideHits.isEmpty)
        #expect(!vm.isSearching)
        vm.query = ""
        vm.search()
        #expect(vm.guideHits.isEmpty)
    }

    @Test("clearing the query while a search is in flight leaves nothing stale")
    func clearedQueryDuringSearch() async throws {
        let vm = try await makeVM()
        vm.query = "inbox"
        vm.search()
        try await Task.sleep(for: .milliseconds(310)) // around the debounce end, reads may be in flight
        let stale = vm.searchTask
        vm.query = ""
        vm.search()
        await stale?.value // the cancelled search has finished writing whatever it writes
        #expect(vm.guideHits.isEmpty)
        #expect(vm.results.isEmpty)
        #expect(!vm.isSearching)
    }

    @Test("FTS-hostile queries neither throw nor crash")
    func hostileQueries() async throws {
        let vm = try await makeVM()
        for q in ["\"", "*", "-", "AND", "\"inbox", "inbox -*"] {
            await searchAndWait(vm, q)
            #expect(vm.errorMessage == nil)
            #expect(!vm.isSearching)
        }
    }

    // #682: the debounce sleep finished while the main actor was busy, the
    // owner cleared the field before the search task got to run, and the
    // stale task then turned the spinner on with nobody left to turn it off.
    @Test("a search cancelled after its debounce elapsed never turns the spinner on")
    func clearedQueryAfterDebounceElapsed() async throws {
        let vm = try await makeVM()
        var reachedDebounce = false
        vm.onSearchStep = { if $0 == .debounce { reachedDebounce = true } }
        vm.query = "inbox"
        vm.search()
        let stale = vm.searchTask
        // Let the search task enter its debounce sleep (the hook fires right
        // before it, with no suspension in between), then hold the main actor
        // past the 300 ms: the sleep completes off-main, so the task resumes
        // without a cancellation error once the main actor is free.
        for _ in 0..<1000 where !reachedDebounce { await Task.yield() }
        try #require(reachedDebounce)
        Thread.sleep(forTimeInterval: 0.5)
        vm.query = ""
        vm.search()
        await stale?.value
        #expect(!vm.isSearching)
        #expect(vm.guideHits.isEmpty)
        #expect(vm.results.isEmpty)
    }

    // #682 review: the query moving on without a new search() call (no
    // cancel, no newer task) must still leave the spinner off at the end.
    @Test("a search whose query moved on mid-read still turns the spinner off")
    func queryMovedOnMidRead() async throws {
        let vm = try await makeVM()
        vm.onSearchStep = { [weak vm] step in
            if step == .reading { vm?.query = "moved on" }
        }
        await searchAndWait(vm, "inbox")
        #expect(!vm.isSearching)
        #expect(vm.guideHits.isEmpty)
    }

    @Test("prefill keeps an existing draft")
    func prefillMerge() {
        #expect(HelpChatPrefill.merge(draft: "", prefill: "q") == "q")
        #expect(HelpChatPrefill.merge(draft: "  ", prefill: "q") == "q")
        #expect(HelpChatPrefill.merge(draft: "q", prefill: "q") == "q")
        #expect(HelpChatPrefill.merge(draft: "mine", prefill: "q") == "mine\nq")
    }
}
