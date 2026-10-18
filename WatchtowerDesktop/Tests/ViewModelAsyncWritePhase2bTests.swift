import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Board #670 phase 2b: the targets, target assistant tabs, workbench board
/// (and, in `ChatViewModelTests`, the main chat) wait on GRDB's writer queue,
/// not on the main thread. Each test holds the writer from another thread,
/// as a busy database would: the state changes only once a write landed, a
/// second press meanwhile does nothing, and what was typed meanwhile stays.
@MainActor
final class ViewModelAsyncWritePhase2bTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ViewModelAsyncWritePhase2bTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeTarget(subItems: String = "[]") throws -> Target {
        let id = try dbManager.dbPool.write { db in
            let id = try TargetQueries.create(db, text: "ship feature", periodStart: "2026-06-01",
                                              periodEnd: "2026-06-30")
            try db.execute(sql: "UPDATE targets SET sub_items = ? WHERE id = ?", arguments: [subItems, id])
            return id
        }
        return try XCTUnwrap(dbManager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    private func storedTarget(_ id: Int) throws -> Target? {
        try dbManager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) }
    }

    // MARK: - Targets

    /// A status change waits for the writer without holding the main actor,
    /// and the list shows it only once it landed.
    func testATargetWriteWhileTheWriterIsBusyChangesNothingUntilItLands() async throws {
        let target = try makeTarget()
        let vm = TargetsViewModel(dbManager: dbManager)
        vm.load()
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let writing = Task { await vm.updateStatus(target, to: "done") }
        let pending = await eventually { vm.isWriting }
        XCTAssertTrue(pending, "the write is under way, waiting for the writer")
        let responsive: Void? = await boundedValue(Task { () }, timeout: .seconds(1))
        XCTAssertNotNil(responsive, "the main actor is free while the write waits")
        XCTAssertEqual(vm.allTargets.first { $0.id == target.id }?.status, "todo")

        held.release()
        let wrote = await writing.value
        XCTAssertTrue(wrote)
        XCTAssertEqual(try storedTarget(target.id)?.status, "done")
        XCTAssertNil(vm.allTargets.first { $0.id == target.id }, "done targets leave the list once stored")
    }

    /// A checklist edit re-reads the row in its own transaction: another item
    /// checked elsewhere after the detail loaded stays checked.
    func testAChecklistToggleKeepsAnotherItemChangedMeanwhile() async throws {
        let shown = try makeTarget(subItems: #"[{"text":"one","done":false},{"text":"two","done":false}]"#)
        try await dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET sub_items = ? WHERE id = ?",
                           arguments: [#"[{"text":"one","done":false},{"text":"two","done":true}]"#, shown.id])
        }
        let vm = TargetsViewModel(dbManager: dbManager)

        let wrote = await vm.toggleSubItem(shown, index: 0)

        XCTAssertTrue(wrote)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(try storedTarget(shown.id)?.decodedSubItems.map(\.done), [true, true])
    }

    /// An edit aimed at a row whose slot now holds another item is refused
    /// rather than landing on the wrong one.
    func testAChecklistEditOfAnItemThatMovedIsRefused() async throws {
        let shown = try makeTarget(subItems: #"[{"text":"one","done":false},{"text":"two","done":false}]"#)
        try await dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET sub_items = ? WHERE id = ?",
                           arguments: [#"[{"text":"two","done":false}]"#, shown.id])
        }
        let vm = TargetsViewModel(dbManager: dbManager)

        let wrote = await vm.removeSubItem(shown, index: 0)

        XCTAssertFalse(wrote)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(try storedTarget(shown.id)?.decodedSubItems.map(\.text), ["two"], "item two is not removed")
    }

    /// A card's Approve while its write waits applies once: the second press
    /// (and Reject) do nothing.
    func testApprovingACardTwiceWhileItsWriteWaitsAppliesItOnce() async throws {
        let target = try makeTarget()
        let conversationID = try await dbManager.dbPool.write { db in
            try ChatConversationQueries.create(db, title: "Task", contextType: "target",
                                               contextID: String(target.id)).id
        }
        let chat = TargetChatViewModel(target: target, viewModel: TargetsViewModel(dbManager: dbManager),
                                       dbManager: dbManager, conversationID: conversationID,
                                       aiService: MockClaudeService())
        defer { chat.stop() }
        let card = TargetActionCard(messageID: UUID(), action: ProposedAction(type: .addSubItem, reason: "r",
                                                                              text: "step"), state: .pending)
        chat.actionCards = [card]
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let first = Task { await chat.approve(card) }
        let applying = await eventually { chat.isApplying(card) }
        XCTAssertTrue(applying)
        await chat.approve(card)
        chat.reject(card)
        XCTAssertEqual(chat.actionCards.first?.state, .pending, "still pending while its write waits")

        held.release()
        await first.value
        guard case .applied = chat.actionCards.first?.state else {
            return XCTFail("\(String(describing: chat.actionCards.first?.state))")
        }
        XCTAssertEqual(try storedTarget(target.id)?.decodedSubItems.map(\.text), ["step"])
    }

    // MARK: - Target assistant tabs

    /// A target's first tab is written on first use: it shows once the row
    /// landed, and a `+` meanwhile opens no second tab.
    func testTheFirstTabShowsOnceItsRowLandsAndOpensOnce() async throws {
        let target = try makeTarget()
        let targets = TargetsViewModel(dbManager: dbManager)
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let assistant = TargetAssistantViewModel(target: target, viewModel: targets, dbManager: dbManager) { id in
            TargetChatViewModel(target: target, viewModel: targets, dbManager: self.dbManager,
                                conversationID: id, aiService: MockClaudeService())
        }
        defer { assistant.stop() }
        XCTAssertNil(assistant.activeChat, "no tab until its row exists")
        XCTAssertTrue(assistant.isCreating)
        let extra = await assistant.newConversation()
        XCTAssertNil(extra, "one tab is being created already")

        held.release()
        let chat = await assistant.readyChat()
        XCTAssertNotNil(chat)
        XCTAssertEqual(assistant.conversations.count, 1)
        let rows = try await dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchAllByContext(db, type: "target", id: String(target.id))
        }
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Workbench board

    private func seedBoard() throws -> (Int64, Int, Int) {
        try dbManager.dbPool.write { db -> (Int64, Int, Int) in
            let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let taskA = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task A")
            let taskB = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task B")
            return (pid, Int(taskA), Int(taskB))
        }
    }

    private func storedIntent(_ id: Int) throws -> String? {
        try storedTarget(id)?.intent
    }

    /// A panel move with the writer busy moves at once; the draft it left
    /// behind is saved once the writer is free.
    func testAPanelMoveWithABusyWriterMovesAtOnceAndSavesAfter() async throws {
        let (pid, taskA, taskB) = try seedBoard()
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        vm.load()
        vm.select(taskA)
        vm.beginDescriptionEdit(taskA)
        vm.setDescriptionDraft("Written on A", for: taskA)
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        vm.select(taskB)

        XCTAssertEqual(vm.selectedTargetID, taskB, "the panel moves at once")
        XCTAssertEqual(vm.descriptionDraft(for: taskA)?.text, "Written on A", "kept until it is stored")
        held.release()
        await vm.writesSettled()
        XCTAssertEqual(try storedIntent(taskA), "Written on A")
        XCTAssertNil(vm.descriptionDraft(for: taskA))
    }

    /// Text typed while a save waited stays in the editor, over the
    /// description just stored, and saves cleanly afterwards.
    func testTextTypedWhileADescriptionSaveWaitsStays() async throws {
        let (pid, taskA, _) = try seedBoard()
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        vm.load()
        vm.select(taskA)
        vm.beginDescriptionEdit(taskA)
        vm.setDescriptionDraft("First", for: taskA)
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let saving = Task { await vm.saveDescription(for: taskA) }
        let waiting = await eventually { vm.isSavingDescription(taskA) }
        XCTAssertTrue(waiting)
        vm.setDescriptionDraft("First, and more", for: taskA)
        held.release()
        let first = await saving.value

        XCTAssertFalse(first, "something is still unsaved")
        XCTAssertEqual(try storedIntent(taskA), "First")
        XCTAssertEqual(vm.descriptionDraft(for: taskA), .init(text: "First, and more", original: "First"))
        let saved = await vm.saveDescription(for: taskA)
        XCTAssertTrue(saved)
        XCTAssertEqual(try storedIntent(taskA), "First, and more")
        XCTAssertNil(vm.errorMessage)
    }

    /// A comment's second send while the first waits adds nothing, and the
    /// composer keeps text typed meanwhile.
    func testACommentSendsOnceAndKeepsTextTypedMeanwhile() async throws {
        let (pid, taskA, _) = try seedBoard()
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        vm.load()
        vm.select(taskA)
        vm.commentDraft = "Use the v2 endpoint"
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let sending = Task { await vm.sendCommentDraft() }
        let pending = await eventually { vm.isSendingComment }
        XCTAssertTrue(pending)
        let second = await vm.sendCommentDraft()
        XCTAssertFalse(second)
        vm.commentDraft = "Use the v2 endpoint, and log it"
        held.release()
        let sent = await sending.value

        XCTAssertTrue(sent)
        XCTAssertEqual(vm.commentDraft, "Use the v2 endpoint, and log it")
        XCTAssertEqual(vm.threads.count, 1)
    }

    // MARK: - Review round (PR #398)

    /// Two items added one after the other while the writer is busy both
    /// land, in order: the field never waits for the first (F1).
    func testTwoChecklistAddsWhileTheWriterIsBusyBothLand() async throws {
        let target = try makeTarget()
        let vm = TargetsViewModel(dbManager: dbManager)
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let first = Task { await vm.addSubItem(target, text: "one") }
        let second = Task { await vm.addSubItem(target, text: "two") }
        let queued = await eventually { vm.isWriting }
        XCTAssertTrue(queued)
        held.release()

        let wroteFirst = await first.value
        let wroteSecond = await second.value
        XCTAssertTrue(wroteFirst)
        XCTAssertTrue(wroteSecond)
        XCTAssertEqual(try storedTarget(target.id)?.decodedSubItems.map(\.text), ["one", "two"])
    }

    /// A row edited after an earlier write moved it (a remove above it, still
    /// queued) lands on that row where it is now, not on its old slot.
    func testAChecklistToggleAfterAQueuedRemoveFindsItsRow() async throws {
        let shown = try makeTarget(subItems: #"[{"text":"one","done":false},{"text":"two","done":false}]"#)
        let vm = TargetsViewModel(dbManager: dbManager)

        let removed = await vm.removeSubItem(shown, index: 0)
        let toggled = await vm.toggleSubItem(shown, index: 1)

        XCTAssertTrue(removed)
        XCTAssertTrue(toggled)
        let stored = try storedTarget(shown.id)?.decodedSubItems
        XCTAssertEqual(stored?.map(\.text), ["two"])
        XCTAssertEqual(stored?.map(\.done), [true])
    }

    /// A composer cleared at submit gets its text back on a failure, ahead
    /// of what was typed since (F1).
    func testAFailedComposerWritePutsTheTextBackAheadOfNewText() {
        XCTAssertEqual(TargetDetailView.restoredDraft(sent: "one", current: ""), "one")
        XCTAssertEqual(TargetDetailView.restoredDraft(sent: "one", current: "two"), "one two")
    }

    /// todo → done → todo picked while the first move waits: the last pick
    /// wins, it is not dropped as a no-op against the board read before (F3).
    func testTheLastStatusPickWinsWhileAMoveWaits() async throws {
        let (pid, taskA, _) = try seedBoard()
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        vm.load()
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        vm.select(taskA)
        vm.setStatus("done")
        vm.setStatus("todo")
        held.release()
        await vm.writesSettled()

        XCTAssertEqual(try storedTarget(taskA)?.status, "todo")
    }

    /// A save asked for while one waits follows it with the latest draft,
    /// and a panel close meanwhile loses nothing (F4).
    func testASaveAskedForWhileOneWaitsFollowsItWithTheLatestDraft() async throws {
        let (pid, taskA, _) = try seedBoard()
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: pid, defaults: defaults)
        vm.load()
        vm.select(taskA)
        vm.beginDescriptionEdit(taskA)
        vm.setDescriptionDraft("First", for: taskA)
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let first = Task { await vm.saveDescription(for: taskA) }
        let waiting = await eventually { vm.isSavingDescription(taskA) }
        XCTAssertTrue(waiting)
        vm.setDescriptionDraft("First, and more", for: taskA)
        let second = Task { await vm.saveDescription(for: taskA) }
        vm.closeDetail()
        held.release()

        _ = await first.value
        let savedAll = await second.value
        await vm.writesSettled()
        XCTAssertTrue(savedAll)
        XCTAssertEqual(try storedIntent(taskA), "First, and more")
        XCTAssertNil(vm.descriptionDraft(for: taskA))
        XCTAssertNil(vm.errorMessage)
    }

    /// A container whose tab is applying a card is never evicted, even over
    /// the center's limit (F7).
    func testAContainerApplyingACardIsNotEvicted() async throws {
        let target = try makeTarget()
        let other = try makeTarget()
        let center = TargetAssistantCenter(limit: 1) { target, targets, manager in
            TargetAssistantViewModel(target: target, viewModel: targets, dbManager: manager) { id in
                TargetChatViewModel(target: target, viewModel: targets, dbManager: manager,
                                    conversationID: id, aiService: MockClaudeService())
            }
        }
        let targets = TargetsViewModel(dbManager: dbManager)
        let busy = center.container(for: target, viewModel: targets, dbManager: dbManager)
        let ready = await busy.readyChat()
        let chat = try XCTUnwrap(ready)
        defer { busy.stop() }
        let action = ProposedAction(type: .addSubItem, reason: "r", text: "step")
        chat.actionCards = [TargetActionCard(messageID: UUID(), action: action, state: .pending)]
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }

        let approving = Task { await chat.approveAll() }
        let applying = await eventually { busy.isAnyWorking && chat.actionCards.contains { chat.isApplying($0) } }
        XCTAssertTrue(applying)
        _ = center.container(for: other, viewModel: targets, dbManager: dbManager)

        XCTAssertTrue(center.container(for: target, viewModel: targets, dbManager: dbManager) === busy,
                      "the busy container survives the trim")
        held.release()
        await approving.value
        XCTAssertEqual(try storedTarget(target.id)?.decodedSubItems.map(\.text), ["step"])
    }
}
