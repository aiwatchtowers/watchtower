import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A process that runs a probe on every input, so a test can see what the
/// DB held at the moment the line was typed.
@MainActor
private final class ProbedSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)?
    var bracketedPasteMode = true
    private(set) var inputs: [[UInt8]] = []
    var onInput: (() -> Void)?

    func start(_ launch: TerminalLaunch) {}
    func detach() {}
    func sendInput(_ bytes: [UInt8]) {
        onInput?()
        inputs.append(bytes)
    }
}

/// `OwnerAsksViewModel.answer(_:with:)`, the structured entry the phone's
/// answers take (mobile POC spec §6.2): validated like a draft, then the
/// draft path's own store-then-deliver step (PROJ-12 unchanged).
@MainActor
final class OwnerAsksStructuredAnswerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [ProbedSession] = []
    private var center: TerminalCenter!
    /// Runs in the pause between an answer's paste and its Return.
    private var onPause: (() async -> Void)?

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
    private let yes = OwnerAskAnswer(answers: [.init(id: "a", labels: ["Yes"])])

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAsksStructuredAnswerTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt asks \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        onPause = nil
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = ProbedSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { _, _ in }, isAlive: { _ in false },
                sleep: { [weak self] _ in await self?.onPause?() }
            )
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        return vm
    }

    /// A workbench (its own folder, so one test may seed several) with one
    /// session row and `count` open asks filed from it.
    private func seed(count: Int = 1, kind: String = "question", payload: String = questions)
        async throws -> (project: Int64, session: TerminalSession, asks: [Int64]) {
        let dir = folder.appendingPathComponent("acme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let acme = dir.path
        let docPath = kind == "review" ? "docs/spec.md" : ""
        return try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
            let asks = try (0..<count).map { _ in
                try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, kind: kind, payload: payload, docPath: docPath)
            }
            return (p, s, asks)
        }
    }

    private func openAsk(_ vm: WorkbenchesViewModel, project: Int64, id: Int64) async throws -> OwnerAsk {
        await vm.asks.load(projectID: project)
        return try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id })
    }

    private func stored(_ id: Int64) async throws -> (status: String, answer: String) {
        try await pool.read { d in
            let row = try XCTUnwrap(Row.fetchOne(d, sql: "SELECT status, answer FROM owner_asks WHERE id = ?", arguments: [id]))
            return (row["status"], row["answer"])
        }
    }

    private func status(_ id: Int64) -> String? {
        try? pool.read { try String.fetchOne($0, sql: "SELECT status FROM owner_asks WHERE id = ?", arguments: [id]) }
    }

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    private enum Scenario: CaseIterable {
        case running, held, noSession
    }

    /// The same Delivery as a draft answer, stored before anything is
    /// typed, for a running session, one at a permission prompt, and none.
    func testAStructuredAnswerStoresBeforeTypingAndDeliversLikeADraftAnswer() async throws {
        let expected: [Scenario: OwnerAsksViewModel.Delivery] = [.running: .submitted, .held: .held, .noSession: .noSession]
        for scenario in Scenario.allCases {
            processes = []
            let (p, s, asks) = try await seed(count: 2)
            let (draftAskID, structuredAskID) = (asks[0], asks[1])
            if scenario != .noSession { center.start(s, fresh: true) }
            let vm = makeVM()
            if scenario == .held {
                vm.asks.needsApproval = { $0 == s.id }
                center.inputAnswersDialog = { $0 == s.id }
            }
            var statusWhenTyped: [String?] = []
            processes.first?.onInput = { [weak self] in statusWhenTyped.append(self?.status(structuredAskID)) }

            let draftAsk = try await openAsk(vm, project: p, id: draftAskID)
            vm.asks.drafts.update(draftAskID) { $0.picks["a"] = .init(labels: ["Yes"]) }
            let draftDelivery = await vm.asks.answer(draftAsk)
            let typedBefore = typed.count
            statusWhenTyped = []

            let structuredAsk = try await openAsk(vm, project: p, id: structuredAskID)
            let outcome = await vm.asks.answer(structuredAsk, with: yes)

            let want = try XCTUnwrap(expected[scenario])
            XCTAssertEqual(draftDelivery, want, "\(scenario): the draft path")
            XCTAssertEqual(outcome, .stored(want), "\(scenario): the structured path delivers alike")
            let row = try await stored(structuredAskID)
            XCTAssertEqual(row.status, "answered", "\(scenario)")
            XCTAssertEqual(try OwnerAskAnswer.decode(row.answer), yes, "\(scenario)")
            XCTAssertEqual(vm.asks.answerNotices[structuredAskID], .delivered(want), "\(scenario)")
            if scenario == .running {
                XCTAssertEqual(typed.count - typedBefore, 2, "one paste, then its Return")
                XCTAssertEqual(statusWhenTyped.first, "answered", "stored before anything is typed")
                let line = OwnerAskPrompt.line(id: structuredAskID, kind: .question, answer: yes)
                XCTAssertTrue(String(bytes: typed[typedBefore], encoding: .utf8)?.contains(line) == true)
            } else {
                XCTAssertTrue(typed.isEmpty, "\(scenario): nothing typed")
            }
            if scenario == .held { XCTAssertEqual(center.answerHints[s.id], .held) }
        }
    }

    func testAnAskWithdrawnMeanwhileIsNotOpenTypesNothingAndKeepsTheDraft() async throws {
        let (p, s, asks) = try await seed()
        let askID = asks[0]
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.drafts.update(askID) { $0.note = "Ship it" }
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [askID])
        }

        let outcome = await vm.asks.answer(ask, with: yes)

        XCTAssertEqual(outcome, .notOpen)
        let row = try await stored(askID)
        XCTAssertEqual(row.status, "withdrawn")
        XCTAssertEqual(row.answer, "")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(vm.asks.drafts.askDraft(for: askID).note, "Ship it", "the Desktop draft is kept")
    }

    /// The guarded write fails (the database refuses it): `.failed` with
    /// the reason, also in `answerErrors`; nothing is typed, the ask stays
    /// open and the Desktop draft is kept.
    func testAFailedWriteIsFailedTypesNothingAndKeepsTheDraft() async throws {
        let (p, s, asks) = try await seed()
        let askID = asks[0]
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.drafts.update(askID) { $0.note = "Ship it" }
        try await pool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_ask_answer BEFORE UPDATE ON owner_asks
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        let outcome = await vm.asks.answer(ask, with: yes)

        guard case let .failed(reason) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(reason.contains("disk full"), reason)
        XCTAssertEqual(vm.asks.answerErrors[askID], reason)
        let row = try await stored(askID)
        XCTAssertEqual(row.status, "open")
        XCTAssertEqual(row.answer, "")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(vm.asks.drafts.askDraft(for: askID).note, "Ship it", "the Desktop draft is kept")
    }

    func testAnUnknownLabelIsInvalidAndWritesNothing() async throws {
        let (p, s, asks) = try await seed()
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: asks[0])

        let outcome = await vm.asks.answer(ask, with: OwnerAskAnswer(answers: [.init(id: "a", labels: ["Maybe"])]))

        XCTAssertEqual(outcome, .invalid(#"answers[0].labels: question "a" has no option "Maybe""#))
        let row = try await stored(asks[0])
        XCTAssertEqual(row.status, "open")
        XCTAssertEqual(row.answer, "")
        XCTAssertTrue(typed.isEmpty)
        XCTAssertNil(vm.asks.answerNotices[asks[0]])
    }

    func testAReviewWithoutAVerdictIsInvalid() async throws {
        let (p, _, asks) = try await seed(kind: "review", payload: "{}")
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: asks[0])

        let outcome = await vm.asks.answer(ask, with: OwnerAskAnswer(note: "Looks fine"))

        XCTAssertEqual(outcome, .invalid(OwnerAskAnswerProblem.verdictRequired.message))
        let row = try await stored(asks[0])
        XCTAssertEqual(row.status, "open")
    }

    func testADesktopDraftIsDiscardedAfterASuccessfulStructuredAnswer() async throws {
        let (p, _, asks) = try await seed()
        let askID = asks[0]
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.drafts.update(askID) {
            $0.picks["a"] = .init(labels: ["No"])
            $0.note = "Keep it off"
        }

        let outcome = await vm.asks.answer(ask, with: yes)

        XCTAssertEqual(outcome, .stored(.noSession))
        XCTAssertTrue(vm.asks.drafts.askDraft(for: askID).isEmpty, "answered elsewhere: the draft goes, as a Desktop answer's does")
        let row = try await stored(askID)
        XCTAssertEqual(try OwnerAskAnswer.decode(row.answer), yes, "the structured answer is what is stored")
    }

    func testAConcurrentDesktopAnswerIsBusyThenNotOpenOnRetry() async throws {
        let (p, s, asks) = try await seed()
        let askID = asks[0]
        center.start(s, fresh: true)
        let vm = makeVM()
        let ask = try await openAsk(vm, project: p, id: askID)
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["No"]) }
        var during: OwnerAsksViewModel.AnswerOutcome?
        let yes = yes
        onPause = { [weak vm] in
            guard let vm, during == nil else { return }
            during = await vm.asks.answer(ask, with: yes)
        }

        let desktop = await vm.asks.answer(ask)
        let retry = await vm.asks.answer(ask, with: yes)

        XCTAssertEqual(desktop, .submitted)
        XCTAssertEqual(during, .busy, "the Desktop answer was still going")
        XCTAssertEqual(retry, .notOpen, "the Desktop answer took the ask")
        let row = try await stored(askID)
        XCTAssertEqual(try OwnerAskAnswer.decode(row.answer).answers, [.init(id: "a", labels: ["No"])])
        XCTAssertEqual(typed.count, 2, "one paste and its Return: the Desktop answer's only")
    }
}
