import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - DigestViewModel

final class DigestViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testLoadDigests() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertDigest(db, channelID: "C001", summary: "Daily standup recap")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.digests.count, 1)
        XCTAssertEqual(vm.digests[0].summary, "Daily standup recap")
        XCTAssertEqual(vm.workspaceDomain, "acme")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadWithTypeFilter() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 100, periodTo: 200, type: "channel")
            try TestDatabase.insertDigest(db, channelID: "", periodFrom: 100, periodTo: 200, type: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.selectedType = "daily"
        vm.load()

        XCTAssertEqual(vm.digests.count, 1)
        XCTAssertEqual(vm.digests[0].type, "daily")
    }

    @MainActor
    func testChannelName() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertDigest(db, channelID: "C001")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.channelName(for: vm.digests[0]), "general")
    }

    @MainActor
    func testChannelNameForDM() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", displayName: "Alice")
            try TestDatabase.insertChannel(db, id: "D001", name: "dm-alice", type: "dm", dmUserID: "U001")
            try TestDatabase.insertDigest(db, channelID: "D001")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.channelName(for: vm.digests[0]), "DM: Alice")
    }

    @MainActor
    func testChannelNameNilForCrossChannel() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "", type: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.channelName(for: vm.digests[0]))
    }

    @MainActor
    func testSlackChannelURL() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try TestDatabase.insertDigest(db, channelID: "C001")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.slackChannelURL(channelID: "C001")?.absoluteString, "slack://channel?team=T001&id=C001")
    }

    @MainActor
    func testSlackChannelURLNilWithoutTeamID() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, id: "", domain: "")
            try TestDatabase.insertDigest(db)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.slackChannelURL(channelID: "C001"))
    }

    @MainActor
    func testSlackMessageURL() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try TestDatabase.insertDigest(db)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let url = vm.slackMessageURL(channelID: "C001", messageTS: "1740577800.000100")
        XCTAssertEqual(url?.absoluteString, "slack://channel?team=T001&id=C001&message=1740577800.000100")
    }

    @MainActor
    func testContributingChannels() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertChannel(db, id: "C002", name: "engineering")
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700000000, periodTo: 1700086400, type: "channel", summary: "ch1")
            try TestDatabase.insertDigest(db, channelID: "C002", periodFrom: 1700000000, periodTo: 1700086400, type: "channel", summary: "ch2")
            try TestDatabase.insertDigest(db, channelID: "", periodFrom: 1700000000, periodTo: 1700086400, type: "daily", summary: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let dailyDigest = try XCTUnwrap(vm.digests.first { $0.type == "daily" })
        let contributing = vm.contributingChannels(for: dailyDigest)
        XCTAssertEqual(contributing.count, 2)
        XCTAssertTrue(contributing.contains { $0.name == "general" })
        XCTAssertTrue(contributing.contains { $0.name == "engineering" })
    }

    @MainActor
    func testContributingChannelsDeduplicates() throws {
        // Same channel can have multiple channel digests within a daily/weekly window
        // (e.g. one per sync cycle). The list must show each channel only once,
        // sorted alphabetically.
        try dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "zeta")
            try TestDatabase.insertChannel(db, id: "C002", name: "alpha")
            // Three channel digests for C001, one for C002 — all in the daily window
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700000000, periodTo: 1700020000, type: "channel", summary: "z1")
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700020001, periodTo: 1700040000, type: "channel", summary: "z2")
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700040001, periodTo: 1700060000, type: "channel", summary: "z3")
            try TestDatabase.insertDigest(db, channelID: "C002", periodFrom: 1700000000, periodTo: 1700086400, type: "channel", summary: "a1")
            try TestDatabase.insertDigest(db, channelID: "", periodFrom: 1700000000, periodTo: 1700086400, type: "daily", summary: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let daily = try XCTUnwrap(vm.digests.first { $0.type == "daily" })
        let contributing = vm.contributingChannels(for: daily)
        XCTAssertEqual(contributing.count, 2, "C001 must collapse to a single entry")
        XCTAssertEqual(contributing[0].name, "alpha", "results must be sorted by name")
        XCTAssertEqual(contributing[1].name, "zeta")
    }

    @MainActor
    func testContributingChannelsEmptyForChannelDigest() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", type: "channel")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.contributingChannels(for: vm.digests[0]).isEmpty)
    }

    @MainActor
    func testDigestByID() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, summary: "Target digest")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        XCTAssertEqual(vm.digestByID(1)?.summary, "Target digest")
    }

    @MainActor
    func testLoadEmptyDB() {
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.digests.isEmpty)
        XCTAssertTrue(vm.ledgerDecisions.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }
}

// MARK: - PeopleViewModel

final class PeopleViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testLoad() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", name: "alice", displayName: "Alice")
            try TestDatabase.insertUser(db, id: "U002", name: "bob", displayName: "Bob")
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, messageCount: 50)
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200, messageCount: 30)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.errorMessage, "load() error: \(vm.errorMessage ?? "")")
        XCTAssertFalse(vm.availableWindows.isEmpty, "no windows found")
        XCTAssertEqual(vm.cards.count, 2)
        XCTAssertEqual(vm.cards[0].userID, "U001")
        XCTAssertEqual(vm.availableWindows.count, 1)
        XCTAssertEqual(vm.userNameCache["U001"], "Alice")
        XCTAssertEqual(vm.userNameCache["U002"], "Bob")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadEmptyDB() {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.cards.isEmpty)
        XCTAssertTrue(vm.availableWindows.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testLoadWindow() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, messageCount: 50)
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 200, periodTo: 300, messageCount: 30)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.cards.count, 1)
        XCTAssertEqual(vm.cards[0].periodFrom, 200)

        vm.loadWindow(at: 1)
        XCTAssertEqual(vm.selectedWindow, 1)
        XCTAssertEqual(vm.cards.count, 1)
        XCTAssertEqual(vm.cards[0].periodFrom, 100)
    }

    @MainActor
    func testLoadWindowOutOfBounds() {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        vm.loadWindow(at: 99)
        XCTAssertEqual(vm.selectedWindow, 0)
    }

    @MainActor
    func testUserName() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", displayName: "Alice")
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.userName(for: "U001"), "Alice")
        XCTAssertEqual(vm.userName(for: "U999"), "U999")
    }

    @MainActor
    func testCurrentWindowLabel() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 1700000000, periodTo: 1700604800)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        let label = vm.currentWindowLabel
        XCTAssertFalse(label.isEmpty)
        XCTAssertNotEqual(label, "No data")
        XCTAssertTrue(label.contains("–"))
    }

    @MainActor
    func testCurrentWindowLabelNoData() {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.currentWindowLabel, "No data")
    }

    @MainActor
    func testRedFlagCount() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, redFlags: #"["Issue"]"#)
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200, redFlags: "[]")
            try TestDatabase.insertPeopleCard(db, userID: "U003", periodFrom: 100, periodTo: 200, redFlags: #"["A","B"]"#)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.redFlagCount, 2)
    }

    @MainActor
    func testCardHistory() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, messageCount: 50)
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 200, periodTo: 300, messageCount: 30)
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200, messageCount: 10)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        let history = vm.cardHistory(userID: "U001")

        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.userID == "U001" })
    }

    @MainActor
    func testUserNameCachePrefersDisplayName() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", name: "alice", displayName: "Alice Wonder")
            try TestDatabase.insertUser(db, id: "U002", name: "bob", displayName: "")
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.userNameCache["U001"], "Alice Wonder")
        XCTAssertEqual(vm.userNameCache["U002"], "bob")
    }
}

// MARK: - AIProvider Tests

final class AIProviderTests: XCTestCase {
    func testProviderDisplayNames() {
        XCTAssertEqual(AIProvider.claude.displayName, "Claude")
        XCTAssertEqual(AIProvider.codex.displayName, "Codex")
        XCTAssertEqual(AIProvider.ollama.displayName, "Ollama")
    }

    func testProviderAllCases() {
        XCTAssertEqual(AIProvider.allCases.count, 3)
    }
}

// MARK: - SearchViewModel

final class SearchViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testEmptyQueryClearsResults() {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "   "
        vm.search()

        XCTAssertTrue(vm.results.isEmpty)
    }

    @MainActor
    func testInitialState() {
        let vm = SearchViewModel(dbManager: dbManager)

        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testSearchSetsIsSearching() async throws {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "hello"
        vm.search()

        // After debounce completes (300ms), isSearching should be set then cleared
        try await Task.sleep(for: .milliseconds(500))

        // After completion, isSearching should be false
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testSearchCancelsOnNewQuery() async throws {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "first"
        vm.search()

        // Immediately issue new search, cancelling previous
        vm.query = "  "
        vm.search()

        XCTAssertTrue(vm.results.isEmpty)
    }

    @MainActor
    func testSearchCancelsPreviousTask() async throws {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "alpha"
        vm.search()

        // Issue second query before debounce completes
        vm.query = "beta"
        vm.search()

        // Wait for debounce
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(vm.isSearching)
    }
}

// MARK: - TracksViewModel

final class TracksViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testLoadTracks() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "Fix the bug", priority: "high", hasUpdates: true)
            try TestDatabase.insertTrack(db, text: "Write docs", priority: "low")
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.errorMessage, "load() error: \(vm.errorMessage ?? "")")
        // Has updates goes to updatedTracks, rest to allTracks
        XCTAssertEqual(vm.updatedTracks.count, 1)
        XCTAssertEqual(vm.allTracks.count, 1)
        XCTAssertEqual(vm.updatedTracks[0].text, "Fix the bug")
        XCTAssertEqual(vm.allTracks[0].text, "Write docs")
        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.updatedCount, 1)
        XCTAssertEqual(vm.workspaceDomain, "acme")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadEmptyDB() {
        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.updatedTracks.isEmpty)
        XCTAssertTrue(vm.allTracks.isEmpty)
        XCTAssertEqual(vm.totalCount, 0)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testLoadWithPriorityFilter() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "High", priority: "high")
            try TestDatabase.insertTrack(db, text: "Low", priority: "low")
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.priorityFilter = "high"
        vm.load()

        XCTAssertEqual(vm.allTracks.count, 1)
        XCTAssertEqual(vm.allTracks[0].text, "High")
    }

    @MainActor
    func testMarkRead() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "Fix it", hasUpdates: true)
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.showRead = true // show read tracks to verify they move correctly
        vm.load()
        XCTAssertEqual(vm.updatedTracks.count, 1)

        let item = vm.updatedTracks[0]
        vm.markRead(item)

        // After markRead, the track moves from updatedTracks to allTracks
        XCTAssertTrue(vm.updatedTracks.isEmpty)
        XCTAssertEqual(vm.allTracks.count, 1)
        let updated = vm.itemByID(item.id)
        XCTAssertTrue(updated?.isRead ?? false)
    }

    @MainActor
    func testSlackMessageURL() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db)
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        let url = vm.slackMessageURL(channelID: "C001", messageTS: "1740577800.000100")
        XCTAssertEqual(url?.absoluteString, "slack://channel?team=T001&id=C001&message=1740577800.000100")
    }

    @MainActor
    func testSlackMessageURLWithoutDomain() {
        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        // No workspace loaded — teamID is nil, so URL should be nil
        let url = vm.slackMessageURL(channelID: "C001", messageTS: "123.456")
        XCTAssertNil(url)
    }

    @MainActor
    func testLoadWithChannelFilter() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "Task 1", channelIDs: #"["C001"]"#)
            try TestDatabase.insertTrack(db, text: "Task 2", channelIDs: #"["C002"]"#)
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.channelFilter = "C002"
        vm.load()

        let total = vm.updatedTracks.count + vm.allTracks.count
        XCTAssertEqual(total, 1)
    }
}

// MARK: - ChatHistoryViewModel

final class ChatHistoryViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testCreateConversation() {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv = vm.createConversation()

        XCTAssertNotNil(conv)
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversationID, conv?.id)
    }

    @MainActor
    func testDeleteConversation() throws {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv = try XCTUnwrap(vm.createConversation())
        XCTAssertEqual(vm.conversations.count, 1)

        vm.deleteConversation(conv.id)
        XCTAssertTrue(vm.conversations.isEmpty)
        XCTAssertNil(vm.selectedConversationID)
    }

    @MainActor
    func testDeleteSelectedSwitchesToFirst() throws {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv1 = try XCTUnwrap(vm.createConversation())
        let conv2 = try XCTUnwrap(vm.createConversation())
        vm.selectedConversationID = conv2.id

        vm.deleteConversation(conv2.id)

        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversationID, conv1.id)
    }

    @MainActor
    func testFilteredConversations() {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        vm.createConversation()
        vm.updateTitle(vm.conversations[0].id, title: "Slack discussion")
        vm.createConversation()
        vm.updateTitle(vm.conversations[0].id, title: "Meeting notes")

        vm.searchText = "slack"
        XCTAssertEqual(vm.filteredConversations.count, 1)
        XCTAssertEqual(vm.filteredConversations[0].title, "Slack discussion")
    }

    @MainActor
    func testFilteredConversationsEmptySearch() {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        vm.createConversation()
        vm.createConversation()

        vm.searchText = ""
        XCTAssertEqual(vm.filteredConversations.count, 2)
    }

    @MainActor
    func testUpdateSessionID() throws {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv = try XCTUnwrap(vm.createConversation())

        vm.updateSessionID(conv.id, sessionID: "sess-abc")

        let updated = vm.conversations.first { $0.id == conv.id }
        XCTAssertEqual(updated?.sessionID, "sess-abc")
    }

    @MainActor
    func testLoad() throws {
        // Create conversations directly in DB
        try dbManager.dbPool.write { db in
            try ChatConversationQueries.create(db, title: "Chat A")
            try ChatConversationQueries.create(db, title: "Chat B")
        }

        let vm = ChatHistoryViewModel(dbManager: dbManager)
        XCTAssertTrue(vm.conversations.isEmpty)

        vm.load()

        // load() is async via Task.detached, give it a moment
        let expectation = XCTestExpectation(description: "load completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(vm.conversations.count, 2)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}

// MARK: - DigestViewModel (additional coverage)

final class DigestViewModelAdditionalTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testMarkDigestRead() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", summary: "Test")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.unreadDigestCount, 1)
        XCTAssertFalse(vm.digests[0].isRead)

        vm.markDigestRead(vm.digests[0].id)

        XCTAssertEqual(vm.unreadDigestCount, 0)
        XCTAssertTrue(vm.digests[0].isRead)
    }

    @MainActor
    func testUnreadDigestCountMultiple() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 100, periodTo: 200, summary: "D1")
            try TestDatabase.insertDigest(db, channelID: "C002", periodFrom: 100, periodTo: 200, summary: "D2")
            try TestDatabase.insertDigest(db, channelID: "C003", periodFrom: 100, periodTo: 200, summary: "D3")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.unreadDigestCount, 3)

        vm.markDigestRead(vm.digests[0].id)
        XCTAssertEqual(vm.unreadDigestCount, 2)

        vm.markDigestRead(vm.digests[1].id)
        XCTAssertEqual(vm.unreadDigestCount, 1)
    }

    @MainActor
    func testDigestByIDNotFound() {
        let vm = DigestViewModel(dbManager: dbManager)
        XCTAssertNil(vm.digestByID(999))
    }
}

// MARK: - UpdateService Version Comparison

final class UpdateServiceTests: XCTestCase {
    func testNewerMajor() {
        XCTAssertTrue(UpdateService.isNewer("1.0.0", than: "0.2.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(UpdateService.isNewer("0.3.0", than: "0.2.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(UpdateService.isNewer("0.2.1", than: "0.2.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(UpdateService.isNewer("0.2.0", than: "0.2.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(UpdateService.isNewer("0.1.0", than: "0.2.0"))
    }

    func testVPrefix() {
        XCTAssertTrue(UpdateService.isNewer("v0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateService.isNewer("v0.3.0", than: "v0.2.0"))
        XCTAssertFalse(UpdateService.isNewer("v0.2.0", than: "v0.2.0"))
    }

    func testDifferentLengths() {
        XCTAssertTrue(UpdateService.isNewer("0.2.1", than: "0.2"))
        XCTAssertFalse(UpdateService.isNewer("0.2", than: "0.2.0"))
    }
}

// MARK: - BackgroundTaskManager

final class BackgroundTaskManagerTests: XCTestCase {

    @MainActor
    func testStepRecordEquality() {
        let r1 = BackgroundTaskManager.StepRecord(
            timestamp: Date(timeIntervalSince1970: 1000),
            pipeline: "digests",
            step: 1,
            total: 10,
            status: "Processing #general",
            inputTokens: 100,
            outputTokens: 50,
            costUsd: 0.001,
            durationSeconds: 5.0
        )
        let r2 = BackgroundTaskManager.StepRecord(
            timestamp: Date(timeIntervalSince1970: 1000),
            pipeline: "digests",
            step: 1,
            total: 10,
            status: "Processing #general",
            inputTokens: 100,
            outputTokens: 50,
            costUsd: 0.001,
            durationSeconds: 5.0
        )
        // Different UUIDs, so not equal
        XCTAssertNotEqual(r1, r2)
        // But same id is equal
        XCTAssertEqual(r1, r1)
    }

    @MainActor
    func testTotalTokensAndCost() throws {
        let manager = BackgroundTaskManager()

        // Totals now come from accumulated progress (not step history sum).
        var digestState = BackgroundTaskManager.TaskState()
        digestState.progress = try decodeProgress("""
            {"pipeline":"digests","done":2,"total":5,"status":"","input_tokens":300,"output_tokens":150,"cost_usd":0.003,"finished":false}
            """)
        var peopleState = BackgroundTaskManager.TaskState()
        peopleState.progress = try decodeProgress("""
            {"pipeline":"people","done":1,"total":3,"status":"","input_tokens":300,"output_tokens":150,"cost_usd":0.003,"finished":false}
            """)
        manager.tasks[.digests] = digestState
        manager.tasks[.people] = peopleState

        XCTAssertEqual(manager.totalInputTokens, 600)
        XCTAssertEqual(manager.totalOutputTokens, 300)

    }

    private func decodeProgress(_ json: String) throws -> InsightProgressData {
        try JSONDecoder().decode(InsightProgressData.self, from: Data(json.utf8))
    }

    @MainActor
    func testTotalTokensEmptyTasks() {
        let manager = BackgroundTaskManager()
        XCTAssertEqual(manager.totalInputTokens, 0)
        XCTAssertEqual(manager.totalOutputTokens, 0)

    }

    @MainActor
    func testHasActiveTasks() {
        let manager = BackgroundTaskManager()
        XCTAssertFalse(manager.hasActiveTasks)

        manager.tasks[.digests] = .init(status: .running)
        XCTAssertTrue(manager.hasActiveTasks)

        manager.tasks[.digests] = .init(status: .done)
        XCTAssertFalse(manager.hasActiveTasks)
    }

    @MainActor
    func testAllFinished() {
        let manager = BackgroundTaskManager()
        XCTAssertTrue(manager.allFinished) // empty is finished

        manager.tasks[.digests] = .init(status: .done)
        manager.tasks[.people] = .init(status: .error("fail"))
        XCTAssertTrue(manager.allFinished)

        manager.tasks[.people] = .init(status: .running)
        XCTAssertFalse(manager.allFinished)
    }

    @MainActor
    func testHasVisibleTasks() {
        let manager = BackgroundTaskManager()
        XCTAssertFalse(manager.hasVisibleTasks)

        manager.tasks[.digests] = .init(status: .done)
        XCTAssertFalse(manager.hasVisibleTasks)

        manager.tasks[.people] = .init(status: .error("oops"))
        XCTAssertTrue(manager.hasVisibleTasks)

        manager.tasks[.people] = .init(status: .pending)
        XCTAssertTrue(manager.hasVisibleTasks)
    }

    // Regression test for a bug where a failed digests phase left tracks/people
    // stuck in `.pending` ("Waiting..." forever in the sidebar) because the
    // pipeline chain returned early instead of isolating the failure. The fix
    // always runs `resolvePendingAsSkipped()` when the chain exits; this test
    // exercises that cleanup directly.
    @MainActor
    func testResolvePendingAsSkippedClearsStuckTasks() {
        let manager = BackgroundTaskManager()
        manager.tasks[.digests] = .init(status: .error("boom"))
        manager.tasks[.tracks] = .init(status: .pending)
        manager.tasks[.people] = .init(status: .pending)

        manager.resolvePendingAsSkipped()

        XCTAssertEqual(manager.tasks[.digests]?.status, .error("boom"))
        XCTAssertEqual(manager.tasks[.tracks]?.status, .error("Skipped"))
        XCTAssertEqual(manager.tasks[.people]?.status, .error("Skipped"))
    }

    @MainActor
    func testResolvePendingAsSkippedLeavesRunningAndDoneUntouched() {
        let manager = BackgroundTaskManager()
        manager.tasks[.digests] = .init(status: .done)
        manager.tasks[.tracks] = .init(status: .running)

        manager.resolvePendingAsSkipped()

        XCTAssertEqual(manager.tasks[.digests]?.status, .done)
        XCTAssertEqual(manager.tasks[.tracks]?.status, .running)
    }
}
