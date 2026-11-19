import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// The morning journal's states (spec §10, §11a): loading, empty, error
/// with Retry, a night, busy, and the daemon-stopped line.
@MainActor
final class WatchmanJournalViewModelTests: XCTestCase {
    private enum ReadError: Error { case broken }

    /// A reader the test steers: each call takes the next reply.
    private final class Replies: @unchecked Sendable {
        var queue: [Result<WatchmanJournalViewModel.Snapshot, Error>]
        var calls = 0
        init(_ queue: [Result<WatchmanJournalViewModel.Snapshot, Error>]) { self.queue = queue }
        func next() throws -> WatchmanJournalViewModel.Snapshot {
            calls += 1
            return try queue.removeFirst().get()
        }
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private func date(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }

    private func model(_ replies: Replies, now: String = "2026-11-17T09:00:00Z") -> WatchmanJournalViewModel {
        let now = date(now)
        return WatchmanJournalViewModel(read: { try replies.next() }, now: { now }, calendar: calendar)
    }

    private func night(decided: [WatchmanItem], pending: [WatchmanItem] = []) -> WatchmanNight {
        WatchmanNight(date: date("2026-11-16T12:00:00Z"), decided: decided, pending: pending, costUSD: 1.5)
    }

    private func item(
        _ id: Int64, question: String = "Store the window per workbench?", unsure: Bool = true, state: String = "done"
    ) -> WatchmanItem {
        WatchmanItem(id: id, workbenchName: "acme-api", sessionID: 3, state: state,
                     outcome: state == "done" ? "answered" : "", question: question, choice: "Per workbench",
                     rationale: "You split settings per workbench.", precedentIDs: [7], confidence: "low",
                     category: "design", unsure: unsure, createdAt: date("2026-11-17T02:14:00Z"))
    }

    func testLoadingThenEmpty() async {
        let replies = Replies([.success(.init(nights: [], deciding: []))])
        let vm = model(replies)
        XCTAssertEqual(vm.phase, .loading)
        XCTAssertEqual(vm.loadingText, "Reading the journal…")
        await vm.load()
        XCTAssertEqual(vm.phase, .empty)
        XCTAssertEqual(vm.emptyCopy.title, "No night yet")
        XCTAssertTrue(vm.emptyHint.contains("Hand to Watchman"))
    }

    func testReadFailureShowsErrorAndRetryReloads() async {
        let replies = Replies([.failure(ReadError.broken), .success(.init(nights: [night(decided: [item(1)])], deciding: []))])
        let vm = model(replies)
        await vm.load()
        XCTAssertEqual(vm.phase, .failed)
        XCTAssertEqual(vm.readFailedText, "Couldn't read the journal. The decisions are stored; nothing was lost.")
        XCTAssertEqual(vm.retryTitle, "Retry")
        await vm.retry()
        XCTAssertEqual(replies.calls, 2)
        XCTAssertEqual(vm.phase, .journal)
        XCTAssertEqual(vm.page?.title, "Tonight")
    }

    /// A reread that fails while a night is on screen keeps the night.
    func testRereadFailureKeepsTheNight() async {
        let replies = Replies([.success(.init(nights: [night(decided: [item(1)])], deciding: [])),
                               .failure(ReadError.broken)])
        let vm = model(replies)
        await vm.load()
        await vm.load()
        XCTAssertEqual(vm.phase, .journal)
        XCTAssertEqual(vm.page?.decided.count, 1)
    }

    func testDecidingItemShowsBusyLine() async {
        let deciding = item(2, question: "Rename the Hold button?", state: "deciding")
        let replies = Replies([.success(.init(nights: [night(decided: [item(1)], pending: [deciding])],
                                              deciding: [deciding]))])
        let vm = model(replies)
        await vm.load()
        XCTAssertEqual(vm.page?.busyLine, "Deciding: Rename the Hold button?")
        XCTAssertEqual(vm.page?.span, "Since 02:14 · Watchman is on")
        XCTAssertEqual(vm.nightRows.first?.live, true)
        XCTAssertEqual(vm.nightRows.first?.line, "In progress · 1 decided so far")
    }

    func testDaemonStoppedLine() async {
        let replies = Replies([.success(.init(nights: [night(decided: [item(1)])], deciding: []))])
        let vm = model(replies)
        await vm.load()
        XCTAssertNil(vm.daemonLine, "unknown: no line")
        vm.daemon = .running
        XCTAssertNil(vm.daemonLine)
        vm.daemon = .stopped
        XCTAssertEqual(vm.daemonLine, "Watchman is not running — the daemon is stopped")
        XCTAssertEqual(vm.phase, .journal, "the last night stays below the line")
    }

    /// Phase 2 journals every decision unsure (D43): each decided card
    /// carries Unsure and there is no sure line.
    func testEveryPhase2DecisionShowsUnsure() async throws {
        let replies = Replies([.success(.init(nights: [night(decided: [item(1), item(2), item(3)])], deciding: []))])
        let vm = model(replies, now: "2026-11-17T13:00:00Z")
        await vm.load()
        let page = try XCTUnwrap(vm.page)
        XCTAssertEqual(page.title, "Night of 16 Nov")
        XCTAssertEqual(page.decided.count, 3)
        XCTAssertTrue(page.decided.allSatisfy { $0.badge == "Unsure" })
        XCTAssertTrue(page.sureLines.isEmpty)
        XCTAssertEqual(page.decidedSummary, "3 unsure")
        XCTAssertEqual(page.cost, "Cost $1.50")
        let card = try XCTUnwrap(page.decided.first)
        XCTAssertEqual(card.place, "acme-api · session 3 · 02:14")
        XCTAssertEqual(card.question, "Store the window per workbench?")
        XCTAssertEqual(card.choice, "Per workbench")
        XCTAssertEqual(card.meta, "confidence low · design")
        XCTAssertEqual(card.outcome, "Answered in the session")
    }

    /// Picking a workbench keeps only its items; the menu names every workbench seen.
    func testScopeKeepsOneWorkbench() async {
        var other = item(2, question: "Other workbench")
        other.workbenchID = 2
        other.workbenchName = "acme-web"
        let replies = Replies([.success(.init(nights: [night(decided: [item(1), other])], deciding: []))])
        let vm = model(replies)
        await vm.load()
        XCTAssertEqual(vm.scopeTitle, "All workbenches")
        XCTAssertEqual(vm.scopeOptions.map(\.name), ["acme-api", "acme-web"])
        vm.scope = 2
        XCTAssertEqual(vm.scopeTitle, "acme-web")
        XCTAssertEqual(vm.page?.decided.map(\.question), ["Other workbench"])
    }

    /// The busy line shows while anything is deciding, whatever night is open.
    func testBusyLineOnAnOlderNight() async {
        let deciding = item(9, question: "Rename the Hold button?", state: "deciding")
        let replies = Replies([.success(.init(nights: [night(decided: [item(1)])], deciding: [deciding]))])
        let vm = model(replies, now: "2026-11-18T09:00:00Z")
        await vm.load()
        XCTAssertEqual(vm.page?.title, "Night of 16 Nov")
        XCTAssertEqual(vm.page?.busyLine, "Deciding: Rename the Hold button?")
    }

    /// Owner-first and superseded items are lines under Decided, never counted.
    func testOwnerFirstLines() async throws {
        var owner = item(5, question: "Use a sheet?")
        owner.outcome = "owner_first"
        var withdrawn = item(6, question: "Keep the old export?")
        withdrawn.outcome = "superseded"
        let night = WatchmanNight(date: date("2026-11-16T12:00:00Z"), ownerFirst: [owner, withdrawn], decided: [item(1)])
        let replies = Replies([.success(.init(nights: [night], deciding: []))])
        let vm = model(replies)
        await vm.load()
        let page = try XCTUnwrap(vm.page)
        XCTAssertEqual(page.decidedCount, 1)
        XCTAssertEqual(page.ownerFirst.map(\.title), ["Use a sheet?", "Keep the old export?"])
        XCTAssertEqual(page.ownerFirst.map(\.note), ["the owner answered first", "The ask was withdrawn before the answer"])
        XCTAssertEqual(page.ownerFirst.map(\.icon), [nil, WatchmanJournalViewModel.supersededIcon],
                       "a superseded line has its own symbol")
    }

    /// While on screen the journal rereads on every tick (the daemon writes
    /// from another process); once the pane's task ends, it stops.
    func testWatchRereadsOnTickUntilCancelled() async {
        let ticker = ManualTick()
        let snapshot = WatchmanJournalViewModel.Snapshot(nights: [night(decided: [item(1)])], deciding: [])
        let reads = Counter()
        let now = date("2026-11-17T09:00:00Z")
        let tick: @Sendable (Duration) async -> Void = { _ in await ticker.wait() }
        let read: @Sendable () async throws -> WatchmanJournalViewModel.Snapshot = { await reads.bump(); return snapshot }
        let vm = WatchmanJournalViewModel(read: read, now: { now }, calendar: calendar, tick: tick)
        let task = Task { await vm.watch() }
        await until { ticker.waiting == 1 }
        XCTAssertEqual(reads.value, 1)
        ticker.fire()
        await until { reads.value == 2 && ticker.waiting == 1 }
        ticker.fire()
        await until { reads.value == 3 && ticker.waiting == 1 }
        task.cancel()
        ticker.fire()
        await task.value
        XCTAssertEqual(reads.value, 3, "no read after the pane left")
    }

    /// The daemon line follows the daemon while the journal is open (final
    /// review D-1): the status is reread with the journal at the start and
    /// on every tick, and no more once the pane left.
    func testWatchRereadsTheStatusOnTick() async {
        let ticker = ManualTick()
        let snapshot = WatchmanJournalViewModel.Snapshot(nights: [night(decided: [item(1)])], deciding: [])
        let statusReads = Counter()
        let now = date("2026-11-17T09:00:00Z")
        let tick: @Sendable (Duration) async -> Void = { _ in await ticker.wait() }
        let vm = WatchmanJournalViewModel(read: { snapshot }, now: { now }, calendar: calendar, tick: tick)
        let task = Task { await vm.watch { statusReads.bump() } }
        await until { ticker.waiting == 1 }
        XCTAssertEqual(statusReads.value, 1, "read when the journal opens")
        ticker.fire()
        await until { statusReads.value == 2 && ticker.waiting == 1 }
        task.cancel()
        ticker.fire()
        await task.value
        XCTAssertEqual(statusReads.value, 2, "no read after the pane left")
    }

    /// Yields until `done` holds (no wall-clock wait).
    private func until(_ done: () -> Bool) async {
        for _ in 0..<10_000 where !done() { await Task.yield() }
        XCTAssertTrue(done())
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// A tick the test fires by hand.
@MainActor
private final class ManualTick {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func fire() {
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}
