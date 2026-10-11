import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// A CLI whose run parks until the test releases it, signalling entry.
private final class ParkedCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    let entered: AsyncStream<Void>
    private let enter: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?

    init() {
        (entered, enter) = AsyncStream<Void>.makeStream()
    }

    func run(args: [String]) async throws -> Data {
        await withCheckedContinuation { continuation in
            lock.withLock { parked = continuation }
            enter.yield()
        }
        return Data(#"{"target_id": 1}"#.utf8)
    }

    func release() {
        lock.withLock {
            parked?.resume()
            parked = nil
        }
    }
}

/// The board write handlers on the hub (mobile POC spec §5.2, §6.3): the
/// Desktop's own writer, the stale-view guard, the board scope, the owner
/// write report and each refusal's reason.
@MainActor
final class BoardHandlersTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var runner: FakeCLIRunner!
    private var reported: [WorkbenchSubject] = []
    private var onOwnerWrite: ((Int64, WorkbenchSubject) -> Void)?

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        runner = FakeCLIRunner(stdout: Data("{\n  \"target_id\": 42\n}\n".utf8))
        reported = []
        onOwnerWrite = nil
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    /// Synchronous reads and writes: inside an async test a bare
    /// `pool.read { }` resolves to GRDB's async overload.
    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.read(body)
    }

    private func written<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.write(body)
    }

    private func makeHandlers(cli: WorkbenchCLI? = nil) -> BoardHandlers {
        BoardHandlers(dbPool: pool, cli: cli ?? WorkbenchCLI(runner: runner)) { [weak self] project, subject in
            self?.reported.append(subject)
            self?.onOwnerWrite?(project, subject)
        }
    }

    private func action(_ kind: ActionKind, entity: Int64?, _ params: [String: JSONValue]) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: kind, entityID: entity.map(String.init), params: params,
            createdAt: Date(), deviceID: "device-a"
        )
    }

    private func statusAction(_ target: Int64, workbench: Int64, to status: String, from: String) -> ActionRequestPayload {
        action(.boardTargetStatus, entity: target, [
            "workbench_id": .integer(workbench), "status": .string(status), "from_status": .string(from)
        ])
    }

    private func createAction(workbench: Int64, text: String, parent: Int64? = nil, intent: String = "") -> ActionRequestPayload {
        var params: [String: JSONValue] = [
            "workbench_id": .integer(workbench), "text": .string(text), "intent": .string(intent), "priority": .string("high")
        ]
        if let parent { params["parent_id"] = .integer(parent) }
        return action(.boardTargetCreate, entity: nil, params)
    }

    private func status(_ id: Int64) throws -> String? {
        try read { try String.fetchOne($0, sql: "SELECT status FROM targets WHERE id = ?", arguments: [id]) }
    }

    private func historyRows(_ id: Int64) throws -> [(to: String, actor: String)] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT to_status, actor FROM target_status_history WHERE target_id = ? ORDER BY id", arguments: [id])
                .map { ($0["to_status"], $0["actor"]) }
        }
    }

    private func comments(on target: Int64) throws -> Int {
        try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project_comments WHERE target_id = ?", arguments: [target]) ?? 0 }
    }

    /// A workbench whose leaf is the only child of mid, the only child of root.
    private func seedChain() throws -> (workbench: Int64, root: Int64, mid: Int64, leaf: Int64) {
        try written { db in
            let p = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Plan")
            let mid = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Feature", parentID: root)
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Task", parentID: mid)
            return (p, root, mid, leaf)
        }
    }

    private func seedTarget(status: String = "todo", priority: String = "medium") throws -> (workbench: Int64, target: Int64) {
        try written { db in
            let p = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            return (p, try TestDatabase.insertWorkbenchTarget(db, projectID: p, status: status, priority: priority))
        }
    }

    // MARK: - Status

    /// PROJ-06 and spec §6.1: the phone's change is the owner's in the
    /// history, and neither it nor the parents the rollup closed is
    /// announced to the owner as the agent's work.
    func testAStatusChangeIsTheOwnersAndNeverNotifiesTheMac() async throws {
        let (p, root, mid, leaf) = try seedChain()
        let suite = "BoardHandlersTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifier = RecordingWorkbenchNotifier()
        let notices = WorkbenchNotificationCenter(dbPool: pool, notifier: notifier, defaults: defaults)
        await notices.poll()
        onOwnerWrite = { [weak notices] in notices?.recordOwnerWrite(projectID: $0, subject: $1) }

        let outcome = try await makeHandlers().handle(statusAction(leaf, workbench: p, to: "done", from: "todo"))
        await notices.poll()

        XCTAssertEqual(outcome, .applied(["status": .string("done")]))
        XCTAssertEqual(try historyRows(leaf).last?.actor, "owner")
        XCTAssertEqual(try status(root), "done", "PROJ-05: the chain rolled up")
        XCTAssertEqual(reported, [.target(leaf)] + [root, mid].sorted().map { .target($0) })
        XCTAssertTrue(notifier.sent.isEmpty, "the owner's own edit is never announced: \(notifier.sent.map(\.title))")
    }

    /// The control for the test above: the same change not reported as the
    /// owner's is announced, so the silence there is the report's doing.
    func testAnUnreportedDoneIsAnnounced() async throws {
        let (p, _, _, leaf) = try seedChain()
        let suite = "BoardHandlersTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifier = RecordingWorkbenchNotifier()
        let notices = WorkbenchNotificationCenter(dbPool: pool, notifier: notifier, defaults: defaults)
        await notices.poll()

        _ = try await makeHandlers().handle(statusAction(leaf, workbench: p, to: "done", from: "todo"))
        await notices.poll()

        XCTAssertFalse(notifier.sent.isEmpty)
    }

    /// PROJ-05: a group's status follows its sub-tasks and is never written.
    func testAStatusOnAGroupIsInvalidParams() async throws {
        let (p, _, mid, _) = try seedChain()

        let outcome = try await makeHandlers().handle(statusAction(mid, workbench: p, to: "blocked", from: "todo"))

        XCTAssertEqual(outcome.reason, .invalidParams)
        XCTAssertEqual(try status(mid), "todo")
        XCTAssertTrue(reported.isEmpty)
    }

    /// Stale view (§5.2 rule 2): the phone showed `todo`, the Mac moved on.
    func testAStaleFromStatusIsAConflictWithTheCurrentStatus() async throws {
        let (p, t) = try seedTarget(status: "in_review")
        let historyBefore = try historyRows(t).count

        let outcome = try await makeHandlers().handle(statusAction(t, workbench: p, to: "done", from: "todo"))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .conflict)
        XCTAssertEqual(outcome.result, ["current": .string("in_review")])
        XCTAssertEqual(try status(t), "in_review", "nothing written")
        XCTAssertEqual(try historyRows(t).count, historyBefore)
        XCTAssertTrue(reported.isEmpty)
    }

    /// The Mac already holds the requested status: applied, nothing written.
    func testACurrentStatusEqualToTheRequestedOneIsAppliedWithoutAWrite() async throws {
        let (p, t) = try seedTarget(status: "in_progress")
        let historyBefore = try historyRows(t).count

        let outcome = try await makeHandlers().handle(statusAction(t, workbench: p, to: "in_progress", from: "todo"))

        XCTAssertEqual(outcome, .applied(["status": .string("in_progress")]))
        XCTAssertEqual(try historyRows(t).count, historyBefore, "no write, no history row")
        XCTAssertTrue(reported.isEmpty, "nothing written, nothing to report")
    }

    func testAStatusOutsideTheEditableOnesIsInvalidParams() async throws {
        let (p, t) = try seedTarget()
        let handlers = makeHandlers()

        for bad in ["snoozed", "archived", ""] {
            let outcome = try await handlers.handle(statusAction(t, workbench: p, to: bad, from: "todo"))
            XCTAssertEqual(outcome.reason, .invalidParams, bad)
        }
        XCTAssertEqual(try status(t), "todo")
    }

    func testAStatusWithoutFromStatusIsInvalidParams() async throws {
        let (p, t) = try seedTarget()

        let outcome = try await makeHandlers().handle(
            action(.boardTargetStatus, entity: t, ["workbench_id": .integer(p), "status": .string("done")])
        )

        XCTAssertEqual(outcome.reason, .invalidParams)
        XCTAssertEqual(try status(t), "todo")
    }

    // MARK: - Priority

    func testAPriorityChangeIsWrittenAndReported() async throws {
        let (p, t) = try seedTarget()
        let request = action(.boardTargetPriority, entity: t, [
            "workbench_id": .integer(p), "priority": .string("high"), "from_priority": .string("medium")
        ])

        let outcome = try await makeHandlers().handle(request)

        XCTAssertEqual(outcome, .applied(["priority": .string("high")]))
        XCTAssertEqual(try read { try String.fetchOne($0, sql: "SELECT priority FROM targets WHERE id = ?", arguments: [t]) }, "high")
        XCTAssertEqual(reported, [.target(t)])
    }

    func testAStalePriorityIsAConflictAndAnUnknownOneIsInvalidParams() async throws {
        let (p, t) = try seedTarget(priority: "low")
        let handlers = makeHandlers()

        let stale = try await handlers.handle(action(.boardTargetPriority, entity: t, [
            "workbench_id": .integer(p), "priority": .string("high"), "from_priority": .string("medium")
        ]))
        let unknown = try await handlers.handle(action(.boardTargetPriority, entity: t, [
            "workbench_id": .integer(p), "priority": .string("urgent"), "from_priority": .string("low")
        ]))
        let same = try await handlers.handle(action(.boardTargetPriority, entity: t, [
            "workbench_id": .integer(p), "priority": .string("low"), "from_priority": .string("high")
        ]))

        XCTAssertEqual(stale.reason, .conflict)
        XCTAssertEqual(stale.result, ["current": .string("low")])
        XCTAssertEqual(unknown.reason, .invalidParams)
        XCTAssertEqual(same, .applied(["priority": .string("low")]))
        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - Comments

    func testACommentIsAnOwnerThreadAndEchoesItsID() async throws {
        let (p, t) = try seedTarget()

        let outcome = try await makeHandlers().handle(
            action(.boardCommentAdd, entity: t, ["workbench_id": .integer(p), "body": .string("Ship it")])
        )

        let id = try XCTUnwrap(try read {
            try Int64.fetchOne($0, sql: "SELECT id FROM project_comments WHERE target_id = ? AND author = 'owner'", arguments: [t])
        })
        XCTAssertEqual(outcome, .applied(["comment_id": .integer(id)]))
        XCTAssertEqual(reported, [.target(t)])
    }

    func testAnEmptyOrOverlongCommentIsInvalidParams() async throws {
        let (p, t) = try seedTarget()
        let handlers = makeHandlers()

        for body in ["  \n ", String(repeating: "a", count: 4001)] {
            let outcome = try await handlers.handle(
                action(.boardCommentAdd, entity: t, ["workbench_id": .integer(p), "body": .string(body)])
            )
            XCTAssertEqual(outcome.reason, .invalidParams)
        }
        let atCap = try await handlers.handle(
            action(.boardCommentAdd, entity: t, ["workbench_id": .integer(p), "body": .string(String(repeating: "a", count: 4000))])
        )
        XCTAssertEqual(atCap.status, .applied)
        XCTAssertEqual(try comments(on: t), 1)
    }

    /// §5.2 rule 3: a target of another workbench, or one on no board.
    func testACommentOffThisBoardIsNotOnBoard() async throws {
        let (p, _) = try seedTarget()
        let (_, other) = try seedTarget()
        let personal = try written { try TestDatabase.insertTarget($0, text: "Personal") }
        let handlers = makeHandlers()

        for target in [other, Int64(personal)] {
            let outcome = try await handlers.handle(
                action(.boardCommentAdd, entity: target, ["workbench_id": .integer(p), "body": .string("Hi")])
            )
            XCTAssertEqual(outcome.reason, .notOnBoard)
        }
        let missing = try await handlers.handle(
            action(.boardCommentAdd, entity: 999_999, ["workbench_id": .integer(p), "body": .string("Hi")])
        )
        XCTAssertEqual(missing.reason, .notFound)
        XCTAssertEqual(try comments(on: other), 0)
    }

    func testAReplyToAResolvedRootReopensIt() async throws {
        let (p, t) = try seedTarget()
        let root = try written { try TestDatabase.insertWorkbenchComment($0, projectID: p, targetID: t, status: "resolved") }

        let outcome = try await makeHandlers().handle(
            action(.boardCommentReply, entity: root, ["workbench_id": .integer(p), "body": .string("One more thing")])
        )

        let reply = try XCTUnwrap(try read {
            try Int64.fetchOne($0, sql: "SELECT id FROM project_comments WHERE parent_id = ?", arguments: [root])
        })
        XCTAssertEqual(outcome, .applied(["comment_id": .integer(reply)]))
        XCTAssertEqual(try read { try String.fetchOne($0, sql: "SELECT status FROM project_comments WHERE id = ?", arguments: [root]) }, "open")
        XCTAssertEqual(reported, [.target(t)])
    }

    func testAReplyUnderAReplyOrAnotherBoardsThreadIsRefused() async throws {
        let (p, t) = try seedTarget()
        let (other, otherTarget) = try seedTarget()
        let (root, child, foreign) = try written { db in
            let root = try TestDatabase.insertWorkbenchComment(db, projectID: p, targetID: t)
            let child = try TestDatabase.insertWorkbenchComment(db, projectID: p, author: "owner", targetID: t, parentID: root)
            return (root, child, try TestDatabase.insertWorkbenchComment(db, projectID: other, targetID: otherTarget))
        }
        let handlers = makeHandlers()

        let underReply = try await handlers.handle(
            action(.boardCommentReply, entity: child, ["workbench_id": .integer(p), "body": .string("Hi")])
        )
        let crossed = try await handlers.handle(
            action(.boardCommentReply, entity: foreign, ["workbench_id": .integer(p), "body": .string("Hi")])
        )
        let missing = try await handlers.handle(
            action(.boardCommentReply, entity: 999_999, ["workbench_id": .integer(p), "body": .string("Hi")])
        )

        XCTAssertEqual(underReply.reason, .invalidParams)
        XCTAssertEqual(crossed.reason, .notOnBoard)
        XCTAssertEqual(missing.reason, .notFound)
        XCTAssertEqual(try comments(on: t), 2, "root and its one reply only")
        XCTAssertEqual(try comments(on: otherTarget), 1)
        _ = root
    }

    // MARK: - Create

    func testACreateRunsTheCLIAsTheOwnerAndEchoesTheNewID() async throws {
        let (p, parent) = try seedTarget()

        let outcome = try await makeHandlers().handle(
            createAction(workbench: p, text: "  -Fix the flaky test  ", parent: parent, intent: "--why it matters")
        )

        XCTAssertEqual(outcome, .applied(["target_id": .integer(42)]))
        XCTAssertEqual(runner.invocations, [[
            "workbench", "target", "add", "--workbench=\(p)", "--title=-Fix the flaky test", "--priority=high",
            "--intent=--why it matters", "--parent=\(parent)", "--json"
        ]])
        XCTAssertEqual(reported, [.target(42)], "the new target; the parent's rollup did not move")
    }

    func testACreateWithAParentOfAnotherWorkbenchIsNotOnBoard() async throws {
        let (p, _) = try seedTarget()
        let (_, foreign) = try seedTarget()

        let outcome = try await makeHandlers().handle(createAction(workbench: p, text: "Child", parent: foreign))

        XCTAssertEqual(outcome.reason, .notOnBoard)
        XCTAssertTrue(runner.invocations.isEmpty, "the CLI never ran")
    }

    func testACreateTitleMustBeOneTo200Characters() async throws {
        let (p, _) = try seedTarget()
        let handlers = makeHandlers()

        let empty = try await handlers.handle(createAction(workbench: p, text: " \n "))
        let long = try await handlers.handle(createAction(workbench: p, text: String(repeating: "a", count: 201)))
        let longIntent = try await handlers.handle(
            createAction(workbench: p, text: "Title", intent: String(repeating: "a", count: 4001))
        )
        XCTAssertEqual(empty.reason, .invalidParams)
        XCTAssertEqual(long.reason, .invalidParams)
        XCTAssertEqual(longIntent.reason, .invalidParams)
        XCTAssertTrue(runner.invocations.isEmpty)

        let atCap = try await handlers.handle(createAction(workbench: p, text: String(repeating: "a", count: 200)))
        XCTAssertEqual(atCap.status, .applied)
    }

    func testAFailedCreateIsWriteFailed() async throws {
        let (p, _) = try seedTarget()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "workbench 1: database is locked")

        let outcome = try await makeHandlers().handle(createAction(workbench: p, text: "Task"))

        XCTAssertEqual(outcome.reason, .writeFailed)
        XCTAssertTrue(outcome.errorMessage?.contains("database is locked") == true, outcome.errorMessage ?? "")
        XCTAssertTrue(reported.isEmpty)
    }

    func testACreateWithoutTheCLIIsWriteFailed() async throws {
        let (p, _) = try seedTarget()

        let outcome = try await BoardHandlers(dbPool: pool, cli: nil) { _, _ in }.handle(createAction(workbench: p, text: "Task"))

        XCTAssertEqual(outcome.reason, .writeFailed)
    }

    /// The CLI hangs: the handler's own timeout answers `outcome_unknown`.
    func testAHungCreateIsCutByTheHandlersTimeout() async throws {
        let (p, _) = try seedTarget()
        let parked = ParkedCLIRunner()
        let handlers = BoardHandlers(
            dbPool: pool, cli: WorkbenchCLI(runner: parked), timeout: .seconds(30),
            sleep: { _ in
                for await _ in parked.entered { return }
            },
            onOwnerWrite: { _, _ in }
        )

        let outcome = try await handlers.handle(createAction(workbench: p, text: "Task"))

        XCTAssertEqual(outcome, .failed(.outcomeUnknown, message: BoardHandlers.timeoutMessage))
        parked.release()
    }

    // MARK: - Review focus 1: the workbench deleted on the Mac

    func testEveryKindForADeletedWorkbenchIsNotFound() async throws {
        let (p, t) = try seedTarget()
        let root = try written { try TestDatabase.insertWorkbenchComment($0, projectID: p, targetID: t) }
        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [p]) }
        let handlers = makeHandlers()
        let requests = [
            statusAction(t, workbench: p, to: "done", from: "todo"),
            action(.boardTargetPriority, entity: t, [
                "workbench_id": .integer(p), "priority": .string("high"), "from_priority": .string("medium")
            ]),
            action(.boardCommentAdd, entity: t, ["workbench_id": .integer(p), "body": .string("Hi")]),
            action(.boardCommentReply, entity: root, ["workbench_id": .integer(p), "body": .string("Hi")]),
            createAction(workbench: p, text: "Task")
        ]

        for request in requests {
            let outcome = try await handlers.handle(request)
            XCTAssertEqual(outcome.reason, .notFound, request.kind.rawValue)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(reported.isEmpty)
    }

    func testMissingParamsAreInvalidParams() async throws {
        let (p, t) = try seedTarget()
        let handlers = makeHandlers()
        let requests = [
            action(.boardTargetStatus, entity: nil, ["workbench_id": .integer(p), "status": .string("done"), "from_status": .string("todo")]),
            action(.boardTargetStatus, entity: t, ["status": .string("done"), "from_status": .string("todo")]),
            action(.boardCommentAdd, entity: t, ["workbench_id": .integer(p)]),
            action(.boardTargetCreate, entity: nil, ["workbench_id": .integer(p), "text": .string("Task")])
        ]

        for request in requests {
            let outcome = try await handlers.handle(request)
            XCTAssertEqual(outcome.reason, .invalidParams, request.kind.rawValue)
        }
    }

    // MARK: - Interrupted apply (§5.2 rule 1)

    /// The hub crashed between `begun` and the comment insert: on restart
    /// the record is echoed `outcome_unknown` and never applied, however
    /// often it is delivered again.
    func testACrashBetweenBegunAndTheInsertNeverWritesASecondComment() async throws {
        let (p, t) = try seedTarget()
        let handlers = makeHandlers()
        let dispatcher = MobileHubCommandDispatcher()
        handlers.register(on: dispatcher)
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        try sidecar.linkTestDevice("device-a")
        let record = try pendingActionRecord(
            kind: .boardCommentAdd, entityID: String(t), params: ["workbench_id": .integer(p), "body": .string("Ship it")]
        )
        try await transport.save([record])
        try sidecar.markRelayBegun(record.recordName, at: Date())

        let processor = RelayProcessor(transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme")
        _ = try await processor.processOnce()
        try await transport.save([record])
        _ = try await processor.processOnce()

        let echoes = try transport.saved.map { try decodeAction($0.record) }.filter { $0.status != .pending }
        XCTAssertEqual(echoes.map(\.status), [.failed, .failed], "the second read re-echoes the stored outcome")
        XCTAssertEqual(echoes.map(\.reason), [.outcomeUnknown, .outcomeUnknown])
        XCTAssertEqual(try comments(on: t), 0, "never applied")
    }

    /// No board to report the write to (the workbenches view model is gone):
    /// the write would land unannounced, so every kind refuses it.
    func testWithoutABoardToReportToAWriteIsRefusedWriteFailed() async throws {
        let (p, t) = try seedTarget()
        let handlers = BoardHandlers(
            dbPool: pool, cli: WorkbenchCLI(runner: runner), isReporting: { false }, onOwnerWrite: { _, _ in }
        )

        let outcome = try await handlers.handle(
            action(.boardCommentAdd, entity: t, ["workbench_id": .integer(p), "body": .string("Ship it")])
        )

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .writeFailed)
        XCTAssertEqual(try comments(on: t), 0, "nothing is written")
    }

    /// Every board kind is registered, and a delivered comment is written once.
    func testTheBoardKindsAreRegisteredAndACommentRelayedTwiceIsWrittenOnce() async throws {
        let (p, t) = try seedTarget()
        let dispatcher = MobileHubCommandDispatcher()
        makeHandlers().register(on: dispatcher)
        for kind: ActionKind in [.boardTargetStatus, .boardTargetPriority, .boardCommentAdd, .boardCommentReply, .boardTargetCreate] {
            XCTAssertTrue(dispatcher.handles(kind), kind.rawValue)
        }
        let transport = StubHubTransport()
        let linked = try HubSyncState.inMemory()
        try linked.linkTestDevice("device-a")
        let processor = RelayProcessor(transport: transport, sidecar: linked, dispatcher: dispatcher, hubID: "hub-acme")
        let record = try pendingActionRecord(
            kind: .boardCommentAdd, entityID: String(t), params: ["workbench_id": .integer(p), "body": .string("Ship it")]
        )

        try await transport.save([record])
        _ = try await processor.processOnce()
        try await transport.save([record])
        _ = try await processor.processOnce()

        let echoes = try transport.saved.map { try decodeAction($0.record) }.filter { $0.status != .pending }
        XCTAssertEqual(echoes.map(\.status), [.applied, .applied], "the second read re-echoes the stored outcome")
        XCTAssertEqual(echoes.first?.result, echoes.last?.result, "the same comment id")
        XCTAssertEqual(try comments(on: t), 1)
    }
}
