import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Go hub phase 3, Task 7 (spec §8 p. 4b): the Workchat composer and an
/// ask's answer reach a session only through the session host's `Deliver`
/// — the app writes none of their bytes to the PTY itself. The stand-in
/// host (`FakeHostDelivery`) records what the app asked; `appInputs` counts
/// the app's own writes.
@MainActor
final class ComposerDeliverTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var defaults: UserDefaults!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt composer \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ComposerDeliverTests-\(UUID().uuidString)"))
        processes = []
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession(pid: 0)
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        center.copyToClipboard = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// The Workchat's line: one `Deliver`, its paragraphs and format
    /// characters kept, not held by the host over text in the prompt (the
    /// composer's own gate holds it before), submitted after the answer
    /// pause. No byte of it is the app's own write.
    func testComposerNeverWritesThePTYDirectly() async throws {
        let acme = folder.path
        let session = try await pool.write { db -> TerminalSession in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .claude, title: "Ship it", folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        center.start(session, fresh: true)
        let delivery = SessionLineDelivery(terminalCenter: center)
        delivery.refreshStates = { true }
        delivery.hasHookState = { _ in true }
        let status = SessionAgentStatus(
            sessionID: session.id, workbenchID: try XCTUnwrap(session.projectID), workbenchName: "acme", title: "Ship it",
            state: .init(kind: .stopped, live: true), at: SessionAgentStatus.formatStamp(Date())
        )
        let control = SessionControl(dbPool: pool, terminalCenter: center, lineDelivery: delivery) { _ in status }
        let model = WorkchatModel(
            sessionID: session.id, control: control, lineDelivery: delivery,
            attachmentStore: WorkchatAttachmentStore(root: folder.appendingPathComponent("att")), kind: { .claude }, now: Date.init
        )
        model.draft = "Fix the flaky test\nthen run the linter"

        await model.send()

        XCTAssertEqual(model.outgoing.first?.state, .sent)
        let process = try XCTUnwrap(processes.first)
        XCTAssertEqual(process.appInputs, 0, "the composer writes nothing to the PTY itself")
        let line = try XCTUnwrap(process.host.lines.first)
        XCTAssertEqual(process.host.lines.count, 1)
        XCTAssertEqual(line.text, "Fix the flaky test\nthen run the linter")
        XCTAssertTrue(line.keepLineBreaks)
        XCTAssertTrue(line.keepFormat)
        XCTAssertTrue(line.submitIf)
        XCTAssertFalse(line.holdIfPromptText)
        XCTAssertEqual(line.settle, AgentInputProfile.claude.submitSettle)
    }

    /// An ask's answer is the host's fixed line through `Deliver` (PROJ-12),
    /// never the app's own write; with its Return asked for.
    func testAskAnswerGoesThroughDeliver() async throws {
        let acme = folder.path
        let (p, s, askID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            return (p, s, ask)
        }
        center.start(s, fresh: true)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        await vm.asks.load(projectID: p)
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["Yes"]) }
        let ask = try XCTUnwrap(vm.asks.openAsks[p]?.first { $0.id == askID })

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        let process = try XCTUnwrap(processes.first)
        XCTAssertEqual(process.appInputs, 0, "the answer is typed by the host")
        let line = try XCTUnwrap(process.host.lines.first)
        XCTAssertEqual(process.host.lines.count, 1)
        XCTAssertTrue(line.text.hasPrefix("Ask #\(askID) answered"), line.text)
        XCTAssertFalse(line.keepLineBreaks)
        XCTAssertTrue(line.submitIf)
        XCTAssertFalse(line.holdIfPromptText)
        XCTAssertEqual(process.host.replies.map(\.canSubmit), [true], "the re-check after the pause allows its Return")
    }
}
