import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The closed asks list in the ask drawer (#1713 spec, "Failure paths and
/// their tests"): opening, reading, live updates, back and Esc, deletes.
@MainActor
final class OwnerAskClosedListTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskClosedListTests-\(UUID().uuidString)"))
        center = TerminalCenter { FakeTerminalSession() }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
    }

    private struct Seeded {
        let project: Int64
        let session: Int64
        let other: Int64
        /// Two closed asks of `session`, the older first.
        let closed: [Int64]
        /// An open ask of `other`.
        let open: Int64
    }

    private func seed() async throws -> Seeded {
        try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: "/tmp/acme")
            let s1 = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "one", folderPath: "/tmp/acme"))
            let s2 = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "two", folderPath: "/tmp/acme"))
            let c1 = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s1.id, title: "Older", status: "answered",
                                                     answer: Self.answer, createdAt: Self.stamp(minutesAgo: 10))
            let c2 = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s1.id, title: "Newer", status: "withdrawn",
                                                     withdrawnReason: "agent", createdAt: Self.stamp(minutesAgo: 5))
            let open = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s2.id, createdAt: Self.stamp(minutesAgo: 1))
            return Seeded(project: p, session: s1.id, other: s2.id, closed: [c1, c2], open: open)
        }
    }

    /// A stored answer: an answered ask must carry one (the table's CHECK).
    nonisolated private static let answer = #"{"verdict":"","answers":[],"checklist":[],"comments":[],"note":""}"#
    /// A question with no id this app reads: the row is left out and named.
    nonisolated private static let unreadablePayload = #"{"questions":[{"question":"One","options":[{"label":"A"}]}]}"#

    nonisolated private static func stamp(minutesAgo minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
    }

    private func key(_ s: Seeded) -> OwnerAsksViewModel.ClosedListKey {
        .init(projectID: s.project, sessionID: s.session)
    }

    /// The workbench selected and its asks read, as on its page.
    private func page(_ s: Seeded) async -> WorkbenchesViewModel {
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project
        await vm.asks.load(projectID: s.project)
        return vm
    }

    private func breakTable() async throws {
        try await pool.write { try $0.execute(sql: "ALTER TABLE owner_asks RENAME TO owner_asks_away") }
    }

    private func mendTable() async throws {
        try await pool.write { try $0.execute(sql: "ALTER TABLE owner_asks_away RENAME TO owner_asks") }
    }

    // MARK: - Opening

    func testOpeningShowsTheSessionAndTheListInItsDrawer() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        XCTAssertTrue(vm.layout(projectID: s.project).showsSession(s.session), "the session's pane is revealed")
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.map(\.id), s.closed.reversed(), "newest first")
        XCTAssertFalse(vm.asks.closedLoading.contains(key(s)))
        XCTAssertNotNil(vm.asks.closedReadAt[key(s)])
    }

    func testTheListOpensBesideTheSessionInWorkchat() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showWorkchat(sessionID: s.session, projectID: s.project)
        XCTAssertEqual(vm.layout(projectID: s.project).visiblePanes, [.sessionChat(s.session)])
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        XCTAssertEqual(vm.layout(projectID: s.project).visiblePanes, [.sessionChat(s.session)], "its mode is kept")
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
    }

    func testTheListReplacesTheDrawersAskAndKeepsItsDraft() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showAsk(s.open, projectID: s.project)
        vm.asks.editDraft(s.open) { $0.note = "half done" }
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
        XCTAssertEqual(vm.asks.drafts.askDraft(for: s.open).note, "half done")
    }

    func testANewAskDoesNotOpenOverTheList() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.sessionPaneMeasured(s.session, projectID: s.project, fits: true)
        _ = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: s.project, sessionID: s.session) }
        await vm.asks.refreshIfChanged(projectID: s.project)
        vm.openNewAsk(projectID: s.project)
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s), "the list stays")
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
    }

    func testASessionlessListOpensWithoutASession() async throws {
        let s = try await seed()
        _ = try await pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: s.project, status: "answered", answer: Self.answer)
        }
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: nil)
        let outside = OwnerAsksViewModel.ClosedListKey(projectID: s.project, sessionID: nil)
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), outside)
        XCTAssertEqual(vm.asks.closedLists[outside]?.count, 1)
    }

    // MARK: - Reads

    func testClosedListFirstReadFailureShowsRetry() async throws {
        let s = try await seed()
        let vm = await page(s)
        try await breakTable()
        await vm.asks.openClosedList(key(s))
        XCTAssertNil(vm.asks.closedLists[key(s)], "nothing read")
        let error = try XCTUnwrap(vm.asks.closedErrors[key(s)])
        XCTAssertTrue(error.hasPrefix("Could not load the closed asks: "), error)
        XCTAssertFalse(vm.asks.closedLoading.contains(key(s)))

        try await mendTable()
        await vm.asks.loadClosed(projectID: s.project, sessionID: s.session)
        XCTAssertNil(vm.asks.closedErrors[key(s)], "Retry read it")
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.count, 2)
    }

    func testClosedListReloadFailureKeepsList() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.asks.openClosedList(key(s))
        let readAt = try XCTUnwrap(vm.asks.closedReadAt[key(s)])
        try await breakTable()
        await vm.asks.loadClosed(projectID: s.project, sessionID: s.session)
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.count, 2, "the list stays")
        let error = try XCTUnwrap(vm.asks.closedErrors[key(s)])
        XCTAssertTrue(error.hasPrefix("Could not refresh the list: "), error)
        XCTAssertTrue(error.hasSuffix("It shows what was read at \(OwnerAsksViewModel.clockTime(readAt))."), error)

        try await mendTable()
        await vm.asks.loadClosed(projectID: s.project, sessionID: s.session)
        XCTAssertNil(vm.asks.closedErrors[key(s)], "the next good read clears it")
    }

    func testClosedListPartialRowsBanner() async throws {
        let s = try await seed()
        let bad = try await pool.write { d in
            try TestDatabase.insertOwnerAsk(d, projectID: s.project, sessionID: s.session, payload: Self.unreadablePayload,
                                            status: "answered", answer: Self.answer)
        }
        let vm = await page(s)
        await vm.asks.openClosedList(key(s))
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.count, 2, "the readable rows")
        XCTAssertEqual(vm.asks.closedUnreadable[key(s)], "1 ask could not be read (#\(bad)).")
        XCTAssertNil(vm.asks.closedErrors[key(s)])
    }

    func testClosedListOlderReadIsDropped() async throws {
        let s = try await seed()
        let vm = await page(s)
        let older = vm.asks.beginClosedRead(key(s))
        let newer = vm.asks.beginClosedRead(key(s))
        let rows = try await pool.read { try OwnerAskQueries.closedAsks($0, projectID: s.project, sessionID: s.session) }
        let fresh = OwnerAsksViewModel.ClosedRead(asks: rows, replaced: [:], counts: [s.session: 2], automationCount: 0, labels: [:])
        vm.asks.finishClosedRead(key(s), generation: newer, result: .success(fresh))
        struct Late: Error {}
        vm.asks.finishClosedRead(key(s), generation: older, result: .failure(Late()))
        XCTAssertNil(vm.asks.closedErrors[key(s)], "the older read finished last and applies nothing")
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.count, 2)
        XCTAssertFalse(vm.asks.closedLoading.contains(key(s)))
    }

    func testClosedListFollowsStatusChange() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        // Go's get_ask delivers the answer; the agent withdraws another round.
        let filed = try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'delivered', delivered_at = '2026-11-10T10:00:00Z' WHERE id = ?",
                          arguments: [s.closed[0]])
            return try TestDatabase.insertOwnerAsk(d, projectID: s.project, sessionID: s.session, status: "withdrawn",
                                                   withdrawnReason: "superseded")
        }
        let reloaded = await vm.asks.refreshIfChanged(projectID: s.project)
        XCTAssertTrue(reloaded)
        let list = try XCTUnwrap(vm.asks.closedLists[key(s)])
        XCTAssertEqual(list.first { $0.id == s.closed[0] }?.status, .delivered, "the chip follows")
        XCTAssertTrue(list.contains { $0.id == filed }, "a newly closed ask appears")
    }

    // MARK: - Rows, back and Esc

    func testClosedListRowOfDeletedAsk() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        try await pool.write { try $0.execute(sql: "DELETE FROM owner_asks WHERE id = ?", arguments: [s.closed[0]]) }
        await vm.openClosedAsk(s.closed[0], from: key(s))
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s), "the list stays")
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
        XCTAssertEqual(vm.asks.closedListNotices[key(s)], ClosedAskListCopy.askGone)
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.map(\.id), [s.closed[1]], "read again")
    }

    func testOpeningARowShowsItReadOnlyWithTheBackRow() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        await vm.openClosedAsk(s.closed[0], from: key(s))
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.closed[0])
        XCTAssertFalse(try XCTUnwrap(vm.asks.drawerAsk(projectID: s.project)).isOpen)
        XCTAssertNil(vm.asks.drawerClosedList(projectID: s.project))
        XCTAssertEqual(vm.asks.closedListOrigins[s.project], key(s))
    }

    func testBackRestoresQueryAndCursor() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.asks.closedListQueries[key(s)] = "older"
        await vm.openClosedAsk(s.closed[0], from: key(s))
        XCTAssertTrue(vm.asks.backToClosedList(projectID: s.project))
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
        XCTAssertNil(vm.asks.closedListOrigins[s.project])
        XCTAssertEqual(vm.asks.closedListQueries[key(s)], "older")
        XCTAssertEqual(vm.asks.closedListCursors[key(s)], s.closed[0], "the cursor sits on the row opened")
    }

    func testEscInOpenedAskGoesBackToList() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        await vm.openClosedAsk(s.closed[1], from: key(s))
        XCTAssertFalse(vm.asks.escapeInDrawer(projectID: s.project, otherModifiers: false, isRepeat: false),
                       "the drawer's keys are not active: Esc is left alone")
        vm.asks.setDrawerKeysActive(true, projectID: s.project)
        XCTAssertFalse(vm.asks.escapeInDrawer(projectID: s.project, otherModifiers: true, isRepeat: false), "⌘Esc")
        XCTAssertFalse(vm.asks.escapeInDrawer(projectID: s.project, otherModifiers: false, isRepeat: true),
                       "a held key's repeat never goes back (its next press would close the list)")
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.closed[1])
        XCTAssertTrue(vm.asks.escapeInDrawer(projectID: s.project, otherModifiers: false, isRepeat: false))
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s), "back, not closed")
    }

    func testEscWithoutListOriginDoesNothing() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showAsk(s.open, projectID: s.project)
        vm.asks.setDrawerKeysActive(true, projectID: s.project)
        XCTAssertFalse(vm.asks.escapeInDrawer(projectID: s.project, otherModifiers: false, isRepeat: false))
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.open, "the drawer is left alone")
    }

    func testOtherOpenClearsListOrigin() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.asks.closedListQueries[key(s)] = "newer"
        await vm.openClosedAsk(s.closed[1], from: key(s))
        await vm.showAsk(s.open, projectID: s.project)
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.open)
        XCTAssertNil(vm.asks.closedListOrigins[s.project], "no back row on an ask opened from the stack")
        XCTAssertNil(vm.asks.drawerClosedList(projectID: s.project))
        XCTAssertEqual(vm.asks.closedListQueries[key(s)], "newer", "the list's query stays for next time")
    }

    func testTheListsKeys() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        let visible = [s.closed[1]]
        XCTAssertFalse(vm.pressInClosedList(.escape, key: key(s), visibleIDs: visible),
                       "no click in the drawer yet: its keys are not taken")
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
        vm.asks.setDrawerKeysActive(true, projectID: s.project)
        XCTAssertTrue(vm.pressInClosedList(.down, key: key(s), visibleIDs: visible))
        XCTAssertEqual(vm.asks.closedListCursors[key(s)], s.closed[1])
        // The search hid the cursor's row: Return opens nothing blind.
        vm.asks.closedListCursors[key(s)] = s.closed[0]
        XCTAssertFalse(vm.pressInClosedList(.open, key: key(s), visibleIDs: visible))
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
        // Esc clears a search first, then closes.
        vm.asks.closedListQueries[key(s)] = "newer"
        XCTAssertTrue(vm.pressInClosedList(.escape, key: key(s), visibleIDs: visible))
        XCTAssertNil(vm.asks.closedListQueries[key(s)])
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s))
        XCTAssertTrue(vm.pressInClosedList(.escape, key: key(s), visibleIDs: visible))
        XCTAssertTrue(vm.asks.drawerIsEmpty(projectID: s.project))
        XCTAssertFalse(vm.pressInClosedList(.search, key: key(s), visibleIDs: visible), "the view's")
    }

    func testReturnOpensTheCursorsVisibleRow() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.asks.closedListCursors[key(s)] = s.closed[0]
        vm.asks.setDrawerKeysActive(true, projectID: s.project)
        XCTAssertTrue(vm.pressInClosedList(.open, key: key(s), visibleIDs: s.closed))
        let deadline = Date().addingTimeInterval(5)
        while vm.asks.drawerAskIDs[s.project] != s.closed[0], Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.asks.drawerAskIDs[s.project], s.closed[0])
        XCTAssertEqual(vm.asks.closedListOrigins[s.project], key(s))
    }

    func testTheCursorMovesWithinTheRows() async throws {
        let s = try await seed()
        let vm = await page(s)
        let ids: [Int64] = [3, 2, 1]
        vm.asks.moveClosedListCursor(key(s), ids: ids, forward: true)
        XCTAssertEqual(vm.asks.closedListCursors[key(s)], 3, "the first press lands on the first row")
        vm.asks.moveClosedListCursor(key(s), ids: ids, forward: true)
        vm.asks.moveClosedListCursor(key(s), ids: ids, forward: true)
        vm.asks.moveClosedListCursor(key(s), ids: ids, forward: true)
        XCTAssertEqual(vm.asks.closedListCursors[key(s)], 1, "stops at the last row")
        vm.asks.moveClosedListCursor(key(s), ids: ids, forward: false)
        XCTAssertEqual(vm.asks.closedListCursors[key(s)], 2)
    }

    func testClosingTheDrawerLeavesTheList() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.asks.closeDrawer(projectID: s.project)
        XCTAssertTrue(vm.asks.drawerIsEmpty(projectID: s.project))
    }

    // MARK: - Sessions and workbenches

    func testClosedListClosesWhenSessionDeleted() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        let session = try XCTUnwrap(vm.terminalSessions[s.project]?.first { $0.id == s.session })
        await vm.delete(session)
        XCTAssertNil(vm.asks.drawerClosedList(projectID: s.project), "its pane is gone, so is the list")
        // Once the DELETE commits, its asks are session-less (ON DELETE SET NULL).
        try await pool.write { try $0.execute(sql: "DELETE FROM terminal_sessions WHERE id = ?", arguments: [s.session]) }
        await vm.asks.load(projectID: s.project)
        XCTAssertEqual(vm.asks.closedCounts[s.project]?[nil], 2, "now counted outside the app")
    }

    func testClosedListOfPendingDeleteSession() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.revealTerminal(projectID: s.project, sessionID: s.session)
        let session = try XCTUnwrap(vm.terminalSessions[s.project]?.first { $0.id == s.session })
        await vm.delete(session)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        XCTAssertTrue(vm.asks.drawerIsEmpty(projectID: s.project), "no drawer for a deleted session")
    }

    func testClosedListSurvivesWorkbenchSwitch() async throws {
        let s = try await seed()
        let other = try await pool.write { try TestDatabase.insertWorkbench($0, folder: "/tmp/other") }
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.drill(into: other)
        XCTAssertNil(vm.asks.drawerClosedList(projectID: other))
        // Changed while the owner was on the other workbench.
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'delivered', delivered_at = '2026-11-10T10:00:00Z' WHERE id = ?",
                          arguments: [s.closed[0]])
        }
        vm.drill(into: s.project)
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s), "kept per workbench")
        await vm.asks.refreshIfChanged(projectID: s.project)
        XCTAssertEqual(vm.asks.closedLists[key(s)]?.first { $0.id == s.closed[0] }?.status, .delivered,
                       "re-read once the fingerprint changed")
    }

    func testAnInFlightReadOfADeletedWorkbenchAppliesNothing() async throws {
        let s = try await seed()
        let vm = await page(s)
        let generation = vm.asks.beginClosedRead(key(s))
        vm.asks.forgetClosedLists(projectID: s.project)
        XCTAssertFalse(vm.asks.closedLoading.contains(key(s)))
        let rows = try await pool.read { try OwnerAskQueries.closedAsks($0, projectID: s.project, sessionID: s.session) }
        let read = OwnerAsksViewModel.ClosedRead(asks: rows, replaced: [:], counts: [:], automationCount: 0, labels: [:])
        vm.asks.finishClosedRead(key(s), generation: generation, result: .success(read))
        XCTAssertNil(vm.asks.closedLists[key(s)], "the read started before the delete is dropped")
    }

    func testAnExpandedListHidesItsSessionsTerminal() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        XCTAssertFalse(vm.isObscured(sessionID: s.session, projectID: s.project), "beside the terminal")
        vm.asks.drawerExpanded = true
        XCTAssertTrue(vm.isObscured(sessionID: s.session, projectID: s.project), "a covered terminal takes no keyboard")
        XCTAssertFalse(vm.isObscured(sessionID: s.other, projectID: s.project))

        await vm.showClosedList(projectID: s.project, sessionID: nil)
        vm.asks.drawerExpanded = true
        XCTAssertTrue(vm.isObscured(sessionID: s.other, projectID: s.project), "a session-less list covers every terminal")
    }

    func testTheListReplacingAnOpenAskCountsAsClosingIt() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showAsk(s.open, projectID: s.project)
        // The session-less list: no other session revealed, the drawer's ask is replaced in place.
        await vm.showClosedList(projectID: s.project, sessionID: nil)
        XCTAssertNil(vm.asks.drawerAskIDs[s.project])
        vm.asks.closeDrawer(projectID: s.project)
        XCTAssertTrue(vm.asks.dismissedAskIDs[s.project]?.contains(s.open) == true,
                      "the open ask does not reopen by itself right after")
    }

    func testARowWhoseReadFailsSaysSoNotGone() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        try await breakTable()
        await vm.openClosedAsk(s.closed[0], from: key(s))
        let notice = try XCTUnwrap(vm.asks.closedListNotices[key(s)])
        XCTAssertTrue(notice.hasPrefix("Could not open the ask: "), notice)
        XCTAssertEqual(vm.asks.drawerClosedList(projectID: s.project), key(s), "the list stays")
        try await mendTable()
    }

    func testClosedListStateDroppedWithWorkbench() async throws {
        let s = try await seed()
        let vm = await page(s)
        await vm.showClosedList(projectID: s.project, sessionID: s.session)
        vm.asks.closedListQueries[key(s)] = "older"
        vm.asks.closedListCursors[key(s)] = s.closed[0]
        vm.asks.forgetClosedLists(projectID: s.project)
        XCTAssertTrue(vm.asks.drawerIsEmpty(projectID: s.project))
        XCTAssertNil(vm.asks.closedLists[key(s)])
        XCTAssertNil(vm.asks.closedListQueries[key(s)])
        XCTAssertNil(vm.asks.closedListCursors[key(s)])
        XCTAssertNil(vm.asks.closedReadAt[key(s)])
    }
}
