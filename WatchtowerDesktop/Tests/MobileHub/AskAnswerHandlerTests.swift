import AppKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// A terminal process that records what is typed into it.
@MainActor
private final class RecordingSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)?
    var bracketedPasteMode = true
    private(set) var inputs: [[UInt8]] = []

    func start(_ launch: TerminalLaunch) {}
    func detach() {}
    func sendInput(_ bytes: [UInt8]) {
        inputs.append(bytes)
    }
}

/// `ask_answer` on the hub (mobile POC spec §5.2, §6.2): the phone's answer
/// through the Desktop's structured entry, each outcome its echo, one store
/// and one line per action, and the handler's own timeout.
@MainActor
final class AskAnswerHandlerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [RecordingSession] = []
    private var center: TerminalCenter!
    /// The workbench models the handlers answer through, kept for the test.
    private var models: [WorkbenchesViewModel] = []
    private var sidecar: HubSyncState!

    nonisolated private static let questions =
        #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
    private let yes: JSONValue = .object([
        "verdict": .string(""),
        "answers": .array([.object(["id": .string("a"), "labels": .array([.string("Yes")]), "other": .string("")])]),
        "checklist": .array([]),
        "comments": .array([]),
        "note": .string("")
    ])

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "AskAnswerHandlerTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt hub asks \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        models = []
        sidecar = try HubSyncState.inMemory()
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = RecordingSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        return vm
    }

    private func makeHandler(_ vm: WorkbenchesViewModel) -> AskAnswerHandler {
        models.append(vm)
        return AskAnswerHandler(dbPool: pool, sidecar: sidecar) { [asks = vm.asks] ask, answer in await asks.answer(ask, with: answer) }
    }

    /// A workbench with one session row and one open ask filed from it.
    private func seed(kind: String = "question", payload: String = questions) async throws -> (project: Int64, session: TerminalSession, ask: Int64) {
        let dir = folder.appendingPathComponent("acme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let acme = dir.path
        return try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
            let docPath = kind == "review" ? "docs/spec.md" : ""
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, kind: kind, payload: payload, docPath: docPath)
            return (p, s, ask)
        }
    }

    private func action(ask: Int64, workbench: Int64, answer: JSONValue? = nil, id: String = UUID().uuidString) -> ActionRequestPayload {
        var params: [String: JSONValue] = ["workbench_id": .integer(workbench)]
        params["answer"] = answer ?? yes
        return ActionRequestPayload(id: id, kind: .askAnswer, entityID: String(ask), params: params, createdAt: Date(), deviceID: "device-a")
    }

    private func stored(_ id: Int64) throws -> (status: String, answer: String) {
        try pool.read { d in
            let row = try XCTUnwrap(Row.fetchOne(d, sql: "SELECT status, answer FROM owner_asks WHERE id = ?", arguments: [id]))
            return (row["status"], row["answer"])
        }
    }

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    private func review(verdict: String, comments: [JSONValue] = []) -> JSONValue {
        .object([
            "verdict": .string(verdict), "answers": .array([]), "checklist": .array([]),
            "comments": .array(comments), "note": .string("")
        ])
    }

    // MARK: - Exactly once

    func testTheSameActionDeliveredTwiceStoresOnceAndTypesOneLine() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        let handler = makeHandler(makeVM())
        let request = action(ask: ask, workbench: p)

        let first = try await handler.handle(request)
        let answeredFirst = try stored(ask)
        let second = try await handler.handle(request)

        XCTAssertEqual(first, .applied(["delivery": .string("submitted")]))
        XCTAssertEqual(second, first, "a re-run is applied again, with the delivery kept")
        XCTAssertEqual(try stored(ask).answer, answeredFirst.answer, "stored once, never rewritten")
        XCTAssertEqual(typed.count, 2, "one paste and its Return")
    }

    /// Through the relay: the same pending record arriving again is never
    /// handled a second time.
    func testTheSameRecordRelayedTwiceTypesOneLineAndReEchoesTheSameOutcome() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        let handler = makeHandler(makeVM())
        let dispatcher = MobileHubCommandDispatcher()
        dispatcher.register(.askAnswer) { try await handler.handle($0) }
        let transport = StubHubTransport()
        let processor = RelayProcessor(transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme")
        let record = try pendingActionRecord(
            kind: .askAnswer, entityID: String(ask), params: ["workbench_id": .integer(p), "answer": yes]
        )

        try await transport.save([record])
        _ = try await processor.processOnce()
        try await transport.save([record])
        _ = try await processor.processOnce()

        let echoes = try transport.saved.map { try decodeAction($0.record) }.filter { $0.status != .pending }
        XCTAssertEqual(echoes.map(\.status), [.applied, .applied], "the second read re-echoes the stored outcome")
        XCTAssertEqual(echoes.map(\.result), Array(repeating: ["delivery": .string("submitted")], count: 2))
        XCTAssertEqual(try stored(ask).status, "answered")
        XCTAssertEqual(typed.count, 2, "one paste and its Return")
    }

    /// The answer is stored and typed, then its echo's save fails (a
    /// transient CloudKit error): the record stays pending, and the next
    /// pass re-runs it — `applied` with the kept delivery, no second line.
    func testARerunAfterAFailedEchoSaveIsAppliedWithTheKeptDelivery() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        let handler = makeHandler(makeVM())
        let dispatcher = MobileHubCommandDispatcher()
        dispatcher.register(.askAnswer) { try await handler.handle($0) }
        let transport = StubHubTransport()
        let processor = RelayProcessor(transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme")
        let record = try pendingActionRecord(
            kind: .askAnswer, entityID: String(ask), params: ["workbench_id": .integer(p), "answer": yes]
        )
        try await transport.save([record])

        transport.failNextSaves(1)
        do {
            _ = try await processor.processOnce()
            XCTFail("the echo's save failed, so the pass fails")
        } catch {
            XCTAssertTrue(error is URLError, "\(error)")
        }
        XCTAssertEqual(try stored(ask).status, "answered", "stored before the echo")
        XCTAssertNotEqual(try sidecar.relayPhase(record.recordName), .done)
        _ = try await processor.processOnce()

        let echoes = try transport.saved.map { try decodeAction($0.record) }.filter { $0.status != .pending }
        XCTAssertEqual(echoes.map(\.status), [.applied])
        XCTAssertEqual(echoes.first?.result, ["delivery": .string("submitted")])
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
        XCTAssertEqual(typed.count, 2, "one paste and its Return")
    }

    /// The same answer already stored with no delivery kept for this
    /// action (the hub stopped before keeping it): `applied`, the delivery
    /// left out, nothing written or typed again.
    func testARerunWithNoKeptDeliveryIsAppliedWithoutOne() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        let read = try await pool.read { try OwnerAskQueries.ask($0, id: ask, projectID: p) }
        let openAsk = try XCTUnwrap(read)
        _ = await vm.asks.answer(openAsk, with: OwnerAskAnswer(answers: [.init(id: "a", labels: ["Yes"])]))
        let typedBefore = typed.count

        let outcome = try await makeHandler(vm).handle(action(ask: ask, workbench: p))

        XCTAssertEqual(outcome, .applied())
        XCTAssertEqual(typed.count, typedBefore, "no second line")
    }

    // MARK: - Go's answer fixtures

    /// `internal/asks/testdata/answers`, the wire Go, the Kit and the hub
    /// share (spec §6.2), sent as the phone sends it.
    private func goFixture(_ name: String) throws -> [String: JSONValue] {
        let repo = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // MobileHub
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent("internal/asks/testdata/answers").appendingPathComponent(name)
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    private func seed(goFixture name: String) async throws -> (project: Int64, ask: Int64, answer: JSONValue, fixture: [String: JSONValue]) {
        let fixture = try goFixture(name)
        guard case let .string(kind)? = fixture["kind"], let payload = fixture["payload"], let answer = fixture["answer"] else {
            XCTFail("malformed fixture \(name)")
            throw CocoaError(.fileReadCorruptFile)
        }
        let payloadJSON = try XCTUnwrap(String(bytes: try JSONEncoder().encode(payload), encoding: .utf8))
        let seeded = try await seed(kind: kind, payload: payloadJSON)
        return (seeded.project, seeded.ask, answer, fixture)
    }

    func testGosValidAnswerFixturesAreStoredAsTheirCanonicalForm() async throws {
        let vm = makeVM()
        for name in ["valid_question.json", "valid_review_changes.json"] {
            let (p, ask, answer, fixture) = try await seed(goFixture: name)

            let outcome = try await makeHandler(vm).handle(action(ask: ask, workbench: p, answer: answer))

            XCTAssertEqual(outcome, .applied(["delivery": .string("no_session")]), name)
            guard case let .string(canonical)? = fixture["canonical"] else { return XCTFail("\(name): no canonical") }
            XCTAssertEqual(try stored(ask).answer, canonical, name)
        }
    }

    func testGosInvalidAnswerFixtureIsInvalidAnswerWithGosMessage() async throws {
        let (p, ask, answer, fixture) = try await seed(goFixture: "invalid_review_no_verdict.json")

        let outcome = try await makeHandler(makeVM()).handle(action(ask: ask, workbench: p, answer: answer))

        guard case let .string(message)? = fixture["error"] else { return XCTFail("no error in the fixture") }
        XCTAssertEqual(outcome, .failed(.invalidAnswer, message: message))
        XCTAssertEqual(try stored(ask).status, "open")
    }

    // MARK: - Deliveries

    func testAStoredAnswerEchoesItsDelivery() async throws {
        // Running → submitted.
        let running = try await seed()
        center.start(running.session, fresh: true)
        let vm = makeVM()
        let submitted = try await makeHandler(vm).handle(action(ask: running.ask, workbench: running.project))
        XCTAssertEqual(submitted, .applied(["delivery": .string("submitted")]))

        // At a permission prompt → held, nothing typed.
        let waiting = try await seed()
        center.start(waiting.session, fresh: true)
        vm.asks.needsApproval = { $0 == waiting.session.id }
        center.inputAnswersDialog = { $0 == waiting.session.id }
        let typedBefore = typed.count
        let held = try await makeHandler(vm).handle(action(ask: waiting.ask, workbench: waiting.project))
        XCTAssertEqual(held, .applied(["delivery": .string("held")]))
        XCTAssertEqual(typed.count, typedBefore, "a held answer types nothing yet")

        // No running session → no_session (the brief delivers it).
        let idle = try await seed()
        let noSession = try await makeHandler(vm).handle(action(ask: idle.ask, workbench: idle.project))
        XCTAssertEqual(noSession, .applied(["delivery": .string("no_session")]))
        XCTAssertEqual(try stored(idle.ask).status, "answered")
    }

    func testEveryOutcomeMapsToItsEcho() {
        let deliveries: [(OwnerAsksViewModel.Delivery, String)] = [
            (.submitted, "submitted"), (.typed, "typed"), (.held, "held"),
            (.queued, "queued"), (.copied, "copied"), (.noSession, "no_session")
        ]
        for (delivery, wire) in deliveries {
            XCTAssertEqual(AskAnswerHandler.outcome(.stored(delivery)), .applied(["delivery": .string(wire)]))
        }
        XCTAssertEqual(AskAnswerHandler.outcome(.notOpen), .failed(.askNotOpen))
        XCTAssertEqual(AskAnswerHandler.outcome(.invalid("bad")), .failed(.invalidAnswer, message: "bad"))
        XCTAssertEqual(AskAnswerHandler.outcome(.busy).reason, .conflict)
        XCTAssertEqual(AskAnswerHandler.outcome(.failed("disk full")), .failed(.writeFailed, message: "disk full"))
    }

    // MARK: - Not open

    /// Review focus 3: the agent superseded the ask while the owner drafted
    /// on the phone; the old ask's answer writes nothing.
    func testASupersededAskIsNotOpen() async throws {
        let (p, s, old) = try await seed()
        center.start(s, fresh: true)
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'superseded' WHERE id = ?", arguments: [old])
            let next = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            try d.execute(sql: "UPDATE owner_asks SET previous_ask_id = ? WHERE id = ?", arguments: [old, next])
        }

        let outcome = try await makeHandler(makeVM()).handle(action(ask: old, workbench: p))

        XCTAssertEqual(outcome, .failed(.askNotOpen))
        XCTAssertEqual(try stored(old).answer, "")
        XCTAssertTrue(typed.isEmpty)
    }

    func testAnAskAnsweredOnTheMacIsNotOpen() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        let mac = #"{"answers":[{"id":"a","labels":["No"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}"#
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'answered', answer = ? WHERE id = ?", arguments: [mac, ask])
        }

        let outcome = try await makeHandler(makeVM()).handle(action(ask: ask, workbench: p))

        XCTAssertEqual(outcome, .failed(.askNotOpen))
        XCTAssertEqual(try stored(ask).answer, mac, "the Mac's answer stays")
        XCTAssertTrue(typed.isEmpty)
    }

    // MARK: - Invalid

    func testAnUnknownLabelIsInvalidAnswer() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        let maybe: JSONValue = .object(["answers": .array([.object(["id": .string("a"), "labels": .array([.string("Maybe")])])])])

        let outcome = try await makeHandler(makeVM()).handle(action(ask: ask, workbench: p, answer: maybe))

        XCTAssertEqual(outcome, .failed(.invalidAnswer, message: #"answers[0].labels: question "a" has no option "Maybe""#))
        XCTAssertEqual(try stored(ask).status, "open")
        XCTAssertTrue(typed.isEmpty)
    }

    func testAReviewWithoutAVerdictIsInvalidAnswer() async throws {
        let (p, _, ask) = try await seed(kind: "review", payload: "{}")

        let outcome = try await makeHandler(makeVM()).handle(action(ask: ask, workbench: p, answer: review(verdict: "")))

        XCTAssertEqual(outcome, .failed(.invalidAnswer, message: OwnerAskAnswerProblem.verdictRequired.message))
        XCTAssertEqual(try stored(ask).status, "open")
    }

    func testAWhitespaceOnlyCommentIsInvalidAnswer() async throws {
        let (p, _, ask) = try await seed(kind: "review", payload: "{}")
        let blank: JSONValue = .object([
            "quote": .string("migrate every row"), "prefix": .string("Step 2: "), "suffix": .string("."),
            "heading": .string("Rollout"), "body": .string("  \n\t ")
        ])

        let outcome = try await makeHandler(makeVM())
            .handle(action(ask: ask, workbench: p, answer: review(verdict: "changes", comments: [blank])))

        XCTAssertEqual(outcome, .failed(.invalidAnswer, message: OwnerAskAnswerProblem.commentBodyRequired(index: 0).message))
        XCTAssertEqual(try stored(ask).status, "open")
    }

    func testAnUnreadableAnswerIsInvalidAnswer() async throws {
        let (p, _, ask) = try await seed(kind: "review", payload: "{}")

        let outcome = try await makeHandler(makeVM()).handle(action(ask: ask, workbench: p, answer: review(verdict: "maybe")))

        XCTAssertEqual(outcome.reason, .invalidAnswer)
        XCTAssertEqual(try stored(ask).status, "open")
    }

    // MARK: - Scope and params

    func testAnAskOfAnotherWorkbenchIsNotFound() async throws {
        let mine = try await seed()
        let other = try await seed()
        center.start(other.session, fresh: true)
        let handler = makeHandler(makeVM())

        let crossed = try await handler.handle(action(ask: other.ask, workbench: mine.project))
        let missing = try await handler.handle(action(ask: other.ask + 1000, workbench: other.project))

        XCTAssertEqual(crossed.reason, .notFound)
        XCTAssertEqual(missing.reason, .notFound)
        XCTAssertEqual(try stored(other.ask).status, "open")
        XCTAssertTrue(typed.isEmpty)
    }

    func testMissingParamsAreInvalidParams() async throws {
        let (p, _, ask) = try await seed()
        let handler = makeHandler(makeVM())
        let noWorkbench = ActionRequestPayload(
            id: UUID().uuidString, kind: .askAnswer, entityID: String(ask), params: ["answer": yes], createdAt: Date()
        )
        let noAnswer = ActionRequestPayload(
            id: UUID().uuidString, kind: .askAnswer, entityID: String(ask), params: ["workbench_id": .integer(p)], createdAt: Date()
        )
        let noEntity = ActionRequestPayload(
            id: UUID().uuidString, kind: .askAnswer, entityID: nil, params: ["workbench_id": .integer(p), "answer": yes], createdAt: Date()
        )

        for request in [noWorkbench, noAnswer, noEntity] {
            let outcome = try await handler.handle(request)
            XCTAssertEqual(outcome.reason, .invalidParams)
        }
        XCTAssertEqual(try stored(ask).status, "open")
    }

    func testAFailedWriteIsWriteFailed() async throws {
        let (p, s, ask) = try await seed()
        center.start(s, fresh: true)
        try await pool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_ask_answer BEFORE UPDATE ON owner_asks
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        let outcome = try await makeHandler(makeVM()).handle(action(ask: ask, workbench: p))

        XCTAssertEqual(outcome.reason, .writeFailed)
        XCTAssertTrue(outcome.errorMessage?.contains("disk full") == true, outcome.errorMessage ?? "")
        XCTAssertTrue(typed.isEmpty)
    }

    // MARK: - Timeout

    func testAHungAnswerIsCutByTheHandlersTimeout() async throws {
        let (p, _, ask) = try await seed()
        var parked: CheckedContinuation<Void, Never>?
        // The timer's sleep ends once the answer is running, and the answer
        // never returns on its own.
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let handler = AskAnswerHandler(
            dbPool: pool, sidecar: sidecar, timeout: .seconds(30),
            sleep: { _ in
                for await _ in entered { return }
            },
            answer: { _, _ in
                enter.yield()
                await withCheckedContinuation { parked = $0 }
                return .stored(.submitted)
            }
        )

        let outcome = try await handler.handle(action(ask: ask, workbench: p))

        XCTAssertEqual(outcome, .failed(.outcomeUnknown, message: AskAnswerHandler.timeoutMessage))
        XCTAssertNotNil(parked, "the answer was running when the timeout fired")
        parked?.resume()
    }

    func testAnAnswerFasterThanTheTimeoutIsItsOwnOutcome() async throws {
        let (p, _, ask) = try await seed()
        let handler = AskAnswerHandler(
            dbPool: pool, sidecar: sidecar, timeout: .seconds(30),
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
            answer: { _, _ in .stored(.typed) }
        )

        let outcome = try await handler.handle(action(ask: ask, workbench: p))

        XCTAssertEqual(outcome, .applied(["delivery": .string("typed")]))
    }
}
