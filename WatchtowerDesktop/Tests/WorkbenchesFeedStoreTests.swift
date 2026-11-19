import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The view model keeps each session's Workchat feed store (#2065 Task 8):
/// reopening a pane paints the kept entries at once and reads only after the
/// cursor; at most `keptFeedStores` are kept, and a kept store off screen
/// runs no CLI.
@MainActor
final class WorkbenchesFeedStoreTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    /// Answers every `session-feed` read with one tail page and records it;
    /// any other call gets `{}`.
    private final class FeedRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var feedCalls: [[String]] { lock.withLock { recorded.filter { $0.contains("session-feed") } } }

        func run(args: [String]) async throws -> Data {
            lock.withLock { recorded.append(args) }
            guard args.contains("session-feed") else { return Data("{}".utf8) }
            let entry = #"{"id":"e1","kind":"agent","at":"2026-10-16T10:00:00Z","text":"hi","conversation":"main"}"#
            return Data(#"{"session_id":1,"cursor":"c1","entries":[\#(entry)],"subagents":[]}"#.utf8)
        }
    }

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesFeedStoreTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: any CLIRunnerProtocol) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    func testFeedStoreKeptPerSession() {
        let vm = makeVM(FeedRunner())
        let first = vm.feedStore(sessionID: 1)
        XCTAssertTrue(first === vm.feedStore(sessionID: 1))
        XCTAssertFalse(first === vm.feedStore(sessionID: 2))
    }

    func testFeedStoreWithoutCLIIsRunnerMissing() {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        XCTAssertTrue(vm.feedStore(sessionID: 1).runnerMissing)
    }

    func testReopenPaintsKeptEntriesAndReadsAfter() async {
        let runner = FeedRunner()
        let vm = makeVM(runner)
        await vm.feedStore(sessionID: 1).refresh()
        let reopened = vm.feedStore(sessionID: 1)
        XCTAssertEqual(reopened.entries.map(\.id), ["e1"], "the kept entries are there before any read")
        XCTAssertEqual(runner.feedCalls.count, 1)
        await reopened.refresh()
        XCTAssertEqual(runner.feedCalls.last?.suffix(2), ["--after", "c1"])
    }

    func testReopenStartsAReopenTrace() async throws {
        let vm = makeVM(FeedRunner())
        let store = vm.feedStore(sessionID: 1)
        await store.refresh()
        store.openTrace?.mark(.paint)
        let firstTrace = try XCTUnwrap(store.openTrace)
        XCTAssertTrue(firstTrace.report?.contains(" first ") ?? false)
        _ = vm.feedStore(sessionID: 1)
        let trace = try XCTUnwrap(store.openTrace)
        XCTAssertFalse(trace === firstTrace, "a kept store shown again times its own open")
        trace.mark(.paint)
        XCTAssertTrue(trace.report?.contains(" reopen ") ?? false)
    }

    func testForgetProcessStateDropsTheStore() {
        let vm = makeVM(FeedRunner())
        let store = vm.feedStore(sessionID: 1)
        vm.forgetProcessState(1)
        XCTAssertFalse(store === vm.feedStore(sessionID: 1))
    }

    func testKeptStoresCappedAtEightLRU() async {
        let runner = FeedRunner()
        let vm = makeVM(runner)
        XCTAssertEqual(WorkbenchesViewModel.keptFeedStores, 8)
        var stores: [Int64: SessionFeedStore] = [:]
        for id in Int64(1)...8 { stores[id] = vm.feedStore(sessionID: id) }
        await stores[1]?.refresh()
        // Session 1 shown again: session 2 is now the least recently shown.
        XCTAssertTrue(vm.feedStore(sessionID: 1) === stores[1])
        _ = vm.feedStore(sessionID: 9)
        XCTAssertTrue(vm.feedStore(sessionID: 1) === stores[1], "the recently shown store stays")
        for id in Int64(3)...8 { XCTAssertTrue(vm.feedStore(sessionID: id) === stores[id]) }
        let reopened = vm.feedStore(sessionID: 2)
        XCTAssertFalse(reopened === stores[2], "the least recently shown store was dropped")
        await reopened.refresh()
        XCTAssertEqual(runner.feedCalls.last?.suffix(2), ["--tail", "60"], "its next open is a cold tail read")
    }

    func testEvictionSkipsOpenPanes() {
        let vm = makeVM(FeedRunner())
        let open = vm.feedStore(sessionID: 1)
        vm.feedPaneAppeared(sessionID: 1)
        var stores: [Int64: SessionFeedStore] = [:]
        for id in Int64(2)...9 { stores[id] = vm.feedStore(sessionID: id) }
        XCTAssertTrue(vm.feedStore(sessionID: 1) === open, "the open pane's store is never dropped")
        XCTAssertFalse(vm.feedStore(sessionID: 2) === stores[2], "the least recently shown closed one goes instead")
        vm.feedPaneDisappeared(sessionID: 1)
        XCTAssertEqual(vm.feedStores.count, WorkbenchesViewModel.keptFeedStores)
    }

    /// The store's own gate: a follow loop that runs while the window is off
    /// screen spawns nothing. A kept store whose pane is closed has no follow
    /// loop at all: that guarantee is structural (`follow` lives in the pane's
    /// `.task`, cancelled with the pane), so this pins the gate only.
    func testHiddenKeptStoreDoesNotPoll() async {
        let runner = FeedRunner()
        let vm = makeVM(runner)
        let store = vm.feedStore(sessionID: 1)
        var ticks = 0
        // Three poll ticks with the pane off screen; `.zero` stands in for the clock.
        await store.follow(interval: .zero, isActive: {
            ticks += 1
            return ticks <= 3
        }, isOnScreen: { false })
        XCTAssertEqual(ticks, 4)
        XCTAssertTrue(runner.feedCalls.isEmpty, "a kept store off screen spawns no CLI")
    }

    func testEarlierPageArrivalKeepsTheTopEntryInViewWhileReading() {
        func entries(_ ids: Range<Int>) -> [SessionFeedEntry] {
            ids.map { SessionFeedEntry(id: "e\($0)", kind: "agent", text: "t") }
        }
        var window = SessionFeedWindow()
        window.setFollowing(false, total: 60)
        XCTAssertEqual(window.earlierPageArrived(entries: entries(0..<120), previousTop: "e60"),
                       WorkchatFeedAdapter.messageID("e60"))
        XCTAssertEqual(window.range(total: 120), 0..<120, "the prepended page is shown")
        var following = SessionFeedWindow()
        XCTAssertNil(following.earlierPageArrived(entries: entries(0..<180), previousTop: "e60"),
                     "a following feed keeps no anchor")
        XCTAssertEqual(following.range(total: 180), 0..<180, "the window grows over the new page")
    }
}
