import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// The page side of a code question, recorded.
@MainActor
private final class FakeQuestionPage: CodeQuestionPage {
    struct Edit: Equatable {
        let bufferID: String
        let range: CodeTextRange
        let text: String
        var expected: String?
    }

    var rect: CGRect? = CGRect(x: 120, y: 48, width: 80, height: 16)
    var rectRequests = 0
    var askRequests = 0
    var askAnswer = true
    var presented: [CGRect] = []
    var closed = 0
    var proposals: [Edit] = []
    var cleared: [String] = []
    var applies: [Edit] = []
    var applyResult: CodeEditApplyResult = .applied

    func requestAskAI() async -> Bool {
        askRequests += 1
        return askAnswer
    }

    func selectionRect() async -> CGRect? {
        rectRequests += 1
        return rect
    }

    func proposeEdit(bufferID: String, range: CodeTextRange, text: String) {
        proposals.append(Edit(bufferID: bufferID, range: range, text: text))
    }

    func clearProposal(bufferID: String) { cleared.append(bufferID) }

    func applyEdit(bufferID: String, range: CodeTextRange, text: String, expected: String) async -> CodeEditApplyResult {
        applies.append(Edit(bufferID: bufferID, range: range, text: text, expected: expected))
        return applyResult
    }

    var presents = true

    func presentQuestionPopover(at rect: CGRect) -> Bool {
        presented.append(rect)
        return presents
    }
    func closeQuestionPopover() { closed += 1 }
}

/// Code questions at the selection (spec 2026-10-02 §9.2): the ✦ button's
/// timing, ⌘I with or without a selection, the conversation kept for the
/// Questions tab, "Suggest a change" as an inline diff and Apply's
/// refusals (PROJ-03).
@MainActor
final class CodeQuestionCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var dbPath: String!
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var project: Workbench!
    private var root: CodeRoot { project.mainCodeRoot }
    private var page: FakeQuestionPage!
    private var ai: ScriptedAIService!
    /// `CodeQuestionCenter.workbenches` is weak, as on `AppState`, which
    /// holds the view model.
    private var workbenchesVM: WorkbenchesViewModel?
    private var now = Date(timeIntervalSinceReferenceDate: 10_000)
    private var sleeps: [TimeInterval] = []
    private var beeps = 0
    private let source = "import Foundation\nlet value = load(config)\nprint(value)\n"

    override func setUpWithError() throws {
        (pool, dbPath) = try TestDatabase.createPool()
        suite = "CodeQuestionCenterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("questions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try source.write(to: folder.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        try "x\n".write(to: folder.appendingPathComponent("Sources/Other.swift"), atomically: true, encoding: .utf8)
        project = Workbench(row: Row(["id": 9, "name": "acme", "folder_path": folder.path]))
        page = FakeQuestionPage()
        ai = ScriptedAIService()
        sleeps = []
        beeps = 0
    }

    override func tearDownWithError() throws {
        workbenchesVM = nil
        pool = nil
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The center over a real Files center, a test database and a scripted
    /// AI; its sleep moves the test clock on by what was asked.
    private func makeCenter(startSearch: CodeSearchStarter? = nil) -> (CodeQuestionCenter, WorkbenchesViewModel, CodeFileBuffer) {
        let center = CodeQuestionCenter(
            clock: { [weak self] in self?.now ?? .distantPast },
            sleep: { [weak self] seconds in
                await MainActor.run {
                    self?.sleeps.append(seconds)
                    self?.now.addTimeInterval(seconds)
                }
            },
            beep: { [weak self] in self?.beeps += 1 },
            defaultChoice: { .init(provider: .claude, model: "") },
            startSearch: startSearch ?? { _, _, _, onDone in
                onDone(.failed("no search in this test"))
                return NoSearch()
            }
        )
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        workbenchesVM = vm
        center.workbenches = vm
        center.dbPool = pool
        let dbPool: DatabasePool = pool
        let ai: ScriptedAIService = ai
        center.embeddedChats = EmbeddedChatCenter { spec, gate in makeSurfaceEngine(spec, dbPool: dbPool, ai: ai, gate: gate) }
        center.registerPage(page, for: project.id)
        let buffer = vm.codeFiles.buffer(for: root, relPath: "Sources/App.swift")
        buffer.loadIfNeeded()
        return (center, vm, buffer)
    }

    private func selection(_ buffer: CodeFileBuffer, _ text: String, _ range: CodeTextRange) -> CodeEditorSelection {
        CodeEditorSelection(bufferID: buffer.id, range: range, text: text, truncated: false)
    }

    private let loadRange = CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 25)

    /// Completes the latest turn with `reply`.
    private func reply(_ reply: String, after calls: Int, engine: EmbeddedChatEngine?) async {
        let started = await eventually { ai.calls.count == calls }
        XCTAssertTrue(started, "turn \(calls) started")
        guard started else { return }
        ai.emit(.text(reply), .turnComplete(reply), .done)
        ai.finish()
        let done = await eventually { engine?.isStreaming == false }
        XCTAssertTrue(done)
    }

    // MARK: The ✦ button

    func testButtonAppearsWhenTheSelectionSettlesAtTheSelectionRect() async {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        XCTAssertNil(center.buttonRects[project.id], "not at once")
        let shown = await eventually { center.buttonRects[project.id] != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(sleeps, [AskAIButtonSchedule.settleDelay], "half a second after the selection")
        XCTAssertEqual(center.buttonRects[project.id], page.rect)
    }

    func testScrollHidesTheButtonAndAClearedSelectionKeepsItHidden() async {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        _ = await eventually { center.buttonRects[project.id] != nil }
        center.editorScrolled(workbenchID: project.id)
        XCTAssertNil(center.buttonRects[project.id], "hidden on scroll")
        let back = await eventually { center.buttonRects[project.id] != nil }
        XCTAssertTrue(back, "back once the scroll settles")

        let requests = page.rectRequests
        center.selectionChanged(selection(buffer, "", CodeTextRange(startLine: 3, startCol: 1, endLine: 3, endCol: 1)),
                                workbenchID: project.id)
        XCTAssertNil(center.buttonRects[project.id], "hidden when the selection clears")
        center.editorScrolled(workbenchID: project.id)
        XCTAssertNil(center.settleTasks[project.id], "no wait without a selection")
        XCTAssertNil(center.buttonRects[project.id])
        XCTAssertEqual(page.rectRequests, requests, "nothing to anchor without a selection")
    }

    /// A selection change while the page answers `selectionRect` wins: the
    /// stale rect is not shown.
    func testASelectionChangeOvertakesTheSettle() async throws {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        let overtaken = try XCTUnwrap(center.settleTasks[project.id])
        center.selectionChanged(selection(buffer, "", CodeTextRange(startLine: 1, startCol: 1, endLine: 1, endCol: 1)),
                                workbenchID: project.id)
        await overtaken.value
        XCTAssertNil(center.settleTasks[project.id])
        XCTAssertNil(center.buttonRects[project.id])
    }

    // MARK: Asking

    /// ⌘I with nothing selected: the question is about the cursor line.
    func testCommandIWithNoSelectionAsksAboutTheCursorLine() async throws {
        let (center, vm, buffer) = makeCenter()
        vm.codeFiles.cursorMoved(CodeNavLocation(path: "Sources/App.swift", line: 2, col: 5), root: root)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        let session = try XCTUnwrap(center.sessions[project.id])
        XCTAssertFalse(session.anchor.isSelection)
        XCTAssertEqual(session.anchor.origin, CodeQuestionOrigin(path: "Sources/App.swift", line: 2, selection: nil))
        XCTAssertEqual(session.context.focusText, "let value = load(config)")
        XCTAssertEqual(session.context.language, "swift")
        XCTAssertEqual(page.presented, [try XCTUnwrap(page.rect)], "the popover points at the caret")
        let rows = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_conversations") }
        XCTAssertEqual(rows, 0, "no conversation before a question is sent")
    }

    func testASelectionIsWhatTheQuestionIsAbout() async throws {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        let session = try XCTUnwrap(center.sessions[project.id])
        XCTAssertTrue(session.anchor.isSelection)
        XCTAssertEqual(session.anchor.range, loadRange)
        XCTAssertEqual(session.context.focusText, "load(config)")
        XCTAssertNil(center.buttonRects[project.id], "the popover replaces the button")
    }

    /// The menu asks the page, which answers with `askAI`; no editor beeps.
    func testMenuAsksThePageAndBeepsWithoutIt() async {
        let (center, _, _) = makeCenter()
        await center.askAIFromMenu(project: project)
        XCTAssertEqual(page.askRequests, 1)
        XCTAssertEqual(beeps, 0)
        page.askAnswer = false
        await center.askAIFromMenu(project: project)
        XCTAssertEqual(beeps, 1)
    }

    /// A popover that could not be shown leaves no question behind: the
    /// next ask works and the ✦ comes back.
    func testAPopoverThatCannotShowLeavesNoQuestion() async throws {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        _ = await eventually { center.buttonRects[project.id] != nil }
        page.presents = false
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        XCTAssertNil(center.sessions[project.id])
        XCTAssertEqual(beeps, 1)
        let back = await eventually { center.buttonRects[project.id] != nil }
        XCTAssertTrue(back, "the ✦ comes back")
        page.presents = true
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        XCTAssertNotNil(center.sessions[project.id], "a later ask is not a no-op")
        XCTAssertEqual(page.presented.count, 2)
    }

    /// #565: a question about a removed worktree's code closes; one about
    /// another root stays.
    func testARemovedWorktreeClosesItsQuestion() async throws {
        let (center, vm, buffer) = makeCenter()
        vm.codeFiles.questions = center
        let worktree = CodeRoot(workbenchID: project.id, worktree: folder.appendingPathComponent(".claude/worktrees/mobile-a"))
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        vm.codeFiles.rootRemoved(worktree)
        XCTAssertNotNil(center.sessions[project.id], "a question about the main folder stays")

        center.closeQuestion(workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: worktree)
        XCTAssertNotNil(center.sessions[project.id])
        vm.codeFiles.rootRemoved(worktree)
        XCTAssertNil(center.sessions[project.id])
    }

    func testAnOpenPopoverIgnoresASecondAskAI() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        XCTAssertEqual(page.presented.count, 1)
        XCTAssertFalse(try XCTUnwrap(center.sessions[project.id]).anchor.isSelection, "the first question stays")
    }

    /// The first question creates the conversation (kept for Questions,
    /// with the picked model); a follow-up continues it.
    func testFirstQuestionCreatesTheConversationAndAFollowUpContinuesIt() async throws {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.setModelChoice(.init(provider: .codex, model: "gpt-5.4"), workbenchID: project.id)
        await center.quickAction(.explain, workbenchID: project.id)
        let engine = center.engine(workbenchID: project.id)
        await reply("It loads the config.", after: 1, engine: engine)
        XCTAssertEqual(ai.calls[0].prompt, CodeQuestionQuickAction.explain.prompt)
        XCTAssertEqual(ai.calls[0].provider, "codex")
        XCTAssertEqual(ai.calls[0].model, "gpt-5.4")
        XCTAssertNil(ai.calls[0].toolMode, "draft-only (AGENT-04)")

        await center.ask("And where is config from?", workbenchID: project.id)
        await reply("From the caller.", after: 2, engine: engine)
        let conversations = try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, context_type, context_id, provider FROM chat_conversations")
        }
        XCTAssertEqual(conversations.count, 1, "one conversation per question")
        XCTAssertEqual(conversations.first?["context_type"], "code_question")
        XCTAssertEqual(conversations.first?["context_id"], "\(project.id):Sources/App.swift:2")
        XCTAssertEqual(conversations.first?["provider"], "codex")
    }

    // MARK: Suggest a change

    private func suggested(_ replacement: String) async throws -> CodeQuestionCenter {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.suggestChange, workbenchID: project.id)
        await reply("Pass the default:\n\n```wt-edit\n\(replacement)\n```", after: 1,
                    engine: center.engine(workbenchID: project.id))
        return center
    }

    func testSuggestAChangeShowsTheDiffOverTheSelection() async throws {
        let center = try await suggested("load(config, default: .standard)")
        let bufferID = try XCTUnwrap(center.sessions[project.id]).bufferID
        XCTAssertEqual(page.proposals, [.init(bufferID: bufferID, range: loadRange, text: "load(config, default: .standard)")])
        XCTAssertEqual(center.sessions[project.id]?.proposal, "load(config, default: .standard)")
    }

    /// A selected line longer than the context's 400-character cut: the
    /// model saw it cut, so its change is not offered for Apply.
    func testASuggestionForALineTheContextCutIsNotOffered() async throws {
        let long = "let value = " + String(repeating: "a", count: 600)
        let file = folder.appendingPathComponent("Sources/App.swift")
        try "import Foundation\n\(long)\n".write(to: file, atomically: true, encoding: .utf8)
        let (center, _, buffer) = makeCenter()
        let range = CodeTextRange(startLine: 2, startCol: 1, endLine: 2, endCol: long.count + 1)
        center.selectionChanged(selection(buffer, long, range), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.suggestChange, workbenchID: project.id)
        await reply("```wt-edit\nlet value = 1\n```", after: 1, engine: center.engine(workbenchID: project.id))
        XCTAssertTrue(page.proposals.isEmpty)
        XCTAssertNil(center.sessions[project.id]?.proposal)
        XCTAssertEqual(center.sessions[project.id]?.notice, CodeEditApplyRefusal.selectionTooLarge.message)
        XCTAssertLessThanOrEqual(ai.calls.first?.systemPrompt?.utf8.count ?? 0, 40 * 1024)
    }

    func testAnAnswerWithoutAWtEditBlockOffersNoApply() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        await reply("It loads the config.", after: 1, engine: center.engine(workbenchID: project.id))
        XCTAssertTrue(page.proposals.isEmpty)
        XCTAssertNil(center.sessions[project.id]?.proposal)
    }

    /// Apply runs one edit in the page, guarded by the question's text.
    func testApplyRunsOneEditGuardedByTheQuestionsText() async throws {
        let center = try await suggested("load(config, default: .standard)")
        await center.applyProposal(workbenchID: project.id)
        XCTAssertEqual(page.applies.count, 1)
        XCTAssertEqual(page.applies.first?.expected, "load(config)")
        XCTAssertEqual(page.applies.first?.range, loadRange)
        XCTAssertNil(center.sessions[project.id]?.proposal)
        XCTAssertEqual(center.sessions[project.id]?.notice, CodeQuestionCenter.appliedNotice)
    }

    /// A follow-up's suggestion applies over the text the first Apply put
    /// there.
    func testAFollowUpSuggestionAppliesOverTheAppliedText() async throws {
        let center = try await suggested("load(config, default: .standard)")
        await center.applyProposal(workbenchID: project.id)
        await center.ask("Shorter, please.", workbenchID: project.id)
        await reply("```wt-edit\nload(.standard)\n```", after: 2, engine: center.engine(workbenchID: project.id))
        await center.applyProposal(workbenchID: project.id)
        XCTAssertEqual(page.applies.count, 2)
        XCTAssertEqual(page.applies.last?.expected, "load(config, default: .standard)")
        XCTAssertEqual(page.applies.last?.range,
                       CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 13 + "load(config, default: .standard)".utf16.count))
        XCTAssertEqual(center.sessions[project.id]?.notice, CodeQuestionCenter.appliedNotice)
    }

    /// The draft typed into the first-question field is sent as it is.
    func testTheFirstQuestionFieldSendsTheCurrentDraft() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        center.setDraft("Why", workbenchID: project.id)
        center.setDraft("Why config?", workbenchID: project.id)
        await center.ask(center.sessions[project.id]?.draft ?? "", workbenchID: project.id)
        await reply("Because.", after: 1, engine: center.engine(workbenchID: project.id))
        XCTAssertEqual(ai.calls.first?.prompt, "Why config?")
        XCTAssertEqual(center.sessions[project.id]?.draft, "", "the field clears once asked")
    }

    func testApplyRefusedWhenTheSelectedTextChanged() async throws {
        let center = try await suggested("load(config, default: .standard)")
        page.applyResult = .changed
        await center.applyProposal(workbenchID: project.id)
        XCTAssertEqual(center.sessions[project.id]?.notice, CodeEditApplyRefusal.selectionChanged.message)
        XCTAssertNotNil(center.sessions[project.id]?.proposal, "the suggestion stays to read")
    }

    /// PROJ-03: a buffer in conflict with its disk version takes no change
    /// until the owner resolves it; the page is never asked.
    func testApplyRefusedWhileTheBufferIsInConflict() async throws {
        let center = try await suggested("load(config, default: .standard)")
        let buffer = try XCTUnwrap(center.workbenches?.codeFiles.existingBuffer(root, "Sources/App.swift"))
        try "changed by the agent\n".write(to: folder.appendingPathComponent("Sources/App.swift"), atomically: false, encoding: .utf8)
        buffer.edited(source + "// mine\n", base: 0, now: true)
        XCTAssertTrue(buffer.conflict)
        await center.applyProposal(workbenchID: project.id)
        XCTAssertTrue(page.applies.isEmpty)
        let notice = try XCTUnwrap(center.sessions[project.id]?.notice)
        XCTAssertTrue(notice.hasPrefix("Not applied: The file changed on disk"), notice)
    }

    func testDiscardRemovesTheDiff() async throws {
        let center = try await suggested("x")
        center.discardProposal(workbenchID: project.id)
        XCTAssertEqual(page.cleared.count, 1)
        XCTAssertNil(center.sessions[project.id]?.proposal)
    }

    // MARK: Closing

    /// Esc closes the popover and its diff; the conversation stays (the
    /// Questions tab lists it) and the button can come back.
    func testEscClosesAndTheConversationStays() async throws {
        let center = try await suggested("x")
        center.closeQuestion(workbenchID: project.id)
        XCTAssertEqual(page.closed, 1)
        XCTAssertEqual(page.cleared.count, 1, "the diff goes with the popover")
        XCTAssertNil(center.sessions[project.id])
        let prefix = "\(project.id):%"
        let listed = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_conversations WHERE context_type = 'code_question' AND context_id LIKE ?",
                             arguments: [prefix])
        }
        XCTAssertEqual(listed, 1)
        center.questionPopoverClosed(workbenchID: project.id)
        XCTAssertEqual(page.cleared.count, 1, "the popover's own close after Esc does nothing more")
    }

    func testLinkOpensTheFileAndClosesThePopover() async throws {
        let (center, vm, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        let link = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "Sources/Other.swift", line: 1, col: nil)))
        await center.openLink(link, workbenchID: project.id)
        XCTAssertEqual(vm.codeFiles.tabs(for: root).active, "Sources/Other.swift")
        XCTAssertNil(center.sessions[project.id])
        XCTAssertEqual(beeps, 0)

        await center.askAI(bufferID: buffer.id, project: project, root: root)
        let gone = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "Sources/Gone.swift", line: 1, col: nil)))
        await center.openLink(gone, workbenchID: project.id)
        XCTAssertEqual(beeps, 1, "a file that is not there beeps")
        XCTAssertNotNil(center.sessions[project.id])
    }

    /// Board #361: a link through a symlink that leaves the folder opens
    /// nothing; one that stays inside opens.
    func testALinkThroughASymlinkLeavingTheFolderOpensNothing() async throws {
        let (center, vm, _) = makeCenter()
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).swift")
        try "secret\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Sources/Leak.swift"),
                                                   withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Sources/Alias.swift").path,
                                                   withDestinationPath: "Other.swift")
        let leak = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "Sources/Leak.swift", line: 1, col: nil)))
        let opened = await center.openLink(leak, project: project, root: root)
        XCTAssertFalse(opened)
        XCTAssertEqual(beeps, 1)
        XCTAssertNil(vm.codeFiles.tabs(for: root).active)
        let alias = try XCTUnwrap(URL(string: CodeLineLinks.url(path: "Sources/Alias.swift", line: 1, col: nil)))
        let openedAlias = await center.openLink(alias, project: project, root: root)
        XCTAssertTrue(openedAlias, "a symlink inside the folder is a file of it")
    }

    /// Board #361: a reopened question's file is read only when it is a
    /// file of the folder; through a symlink leaving it, nothing is read.
    func testAReopenedQuestionNeverReadsThroughASymlinkLeavingTheFolder() throws {
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).swift")
        try "secret\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Leak.swift"), withDestinationURL: outside)
        XCTAssertNil(CodeQuestionCenter.readFolderFile("Leak.swift", folder: folder.path))
        XCTAssertNil(CodeQuestionCenter.readFolderFile("../\(outside.lastPathComponent)", folder: folder.path))
        XCTAssertEqual(CodeQuestionCenter.readFolderFile("Sources/App.swift", folder: folder.path), source)
    }

    func testThePaneGoingAwayClearsTheQuestion() async {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        center.unregisterPage(page, for: project.id)
        XCTAssertNil(center.sessions[project.id])
        XCTAssertNil(center.buttonRects[project.id])
    }

    /// The answer outlives the popover and the pane (review-rules
    /// "Lifecycle & state"): the engine lives in `EmbeddedChatCenter`, so
    /// leaving mid-answer keeps it streaming and the reply is stored.
    func testAnAnswerKeepsStreamingAfterThePaneGoesAway() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        let engine = try XCTUnwrap(center.engine(workbenchID: project.id))
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        center.closeQuestion(workbenchID: project.id)
        center.unregisterPage(page, for: project.id)
        XCTAssertTrue(engine.isStreaming, "leaving does not stop the answer")
        ai.emit(.text("It loads the config."), .turnComplete("It loads the config."), .done)
        ai.finish()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        let stored = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM chat_messages WHERE role = 'assistant' AND status = 'complete'")
        }
        XCTAssertEqual(stored, "It loads the config.")
        XCTAssertTrue(page.proposals.isEmpty, "no diff for a closed popover")
    }

    // MARK: Where is it used? (ruling R45)

    private func stubStarter(_ stub: CodeCLIStub, _ extra: [String: String] = [:]) -> CodeSearchStarter {
        let executable = stub.executable.path
        let environment = stub.environment(extra)
        return { folder, options, onMatch, onDone in
            CodeSearchRun.start(folder: folder, options: options, executable: executable, environment: environment,
                                onMatch: onMatch, onDone: onDone)
        }
    }

    /// The selected name is searched whole-word and case-sensitive, and the
    /// locations reach the first turn's context before it is sent.
    func testWhereUsedAttachesTheSearchResultsToTheFirstTurn() async throws {
        let stub = try CodeCLIStub()
        defer { stub.remove() }
        var searched: [CodeSearchOptions] = []
        let real = stubStarter(stub, ["STUB_SEARCH_DONE": "1"])
        let (center, _, buffer) = makeCenter { folder, options, onMatch, onDone in
            searched.append(options)
            return real(folder, options, onMatch, onDone)
        }
        let loadName = CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 17)
        center.selectionChanged(selection(buffer, "load", loadName), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.whereUsed, workbenchID: project.id)
        XCTAssertEqual(center.sessions[project.id]?.isSearchingUsages, true, "the question waits for the search")
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(searched, [CodeSearchOptions(query: "load", word: true, caseSensitive: true, max: 30, context: 0)])
        let system = try XCTUnwrap(ai.calls.first?.systemPrompt)
        XCTAssertTrue(system.contains("Usages of `load`"), system)
        XCTAssertTrue(system.contains("- a.swift:1: hit"), system)
        XCTAssertEqual(ai.calls.first?.prompt, CodeQuestionQuickAction.whereUsed.prompt)
        ai.emit(.text("At a.swift:1."), .turnComplete("At a.swift:1."), .done)
        ai.finish()
        await stub.assertAllGroupsReaped()
    }

    /// As a follow-up on a resumed Claude session (no system prompt), the
    /// locations ride with that turn's prompt, once.
    func testWhereUsedAsAFollowUpCarriesTheResultsInTheTurn() async throws {
        let stub = try CodeCLIStub()
        defer { stub.remove() }
        let (center, _, buffer) = makeCenter(startSearch: stubStarter(stub, ["STUB_SEARCH_DONE": "1"]))
        center.selectionChanged(selection(buffer, "load", CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 17)),
                                workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        let engine = center.engine(workbenchID: project.id)
        _ = await eventually { ai.calls.count == 1 }
        ai.emit(.sessionID("s1"), .text("It loads."), .turnComplete("It loads."), .done)
        ai.finish()
        _ = await eventually { engine?.isStreaming == false }
        await center.quickAction(.whereUsed, workbenchID: project.id)
        await reply("At a.swift:1.", after: 2, engine: engine)
        XCTAssertNil(ai.calls[1].systemPrompt, "the session already holds the context")
        XCTAssertTrue(ai.calls[1].prompt.contains("- a.swift:1: hit"), ai.calls[1].prompt)
        await center.ask("Thanks", workbenchID: project.id)
        await reply("ok", after: 3, engine: engine)
        XCTAssertEqual(ai.calls[2].prompt, "Thanks", "attached once")
        await stub.assertAllGroupsReaped()
    }

    /// A phrase selection with no cursor on a name sends without a search.
    func testWhereUsedWithoutANameSendsAtOnce() async throws {
        var searches = 0
        let (center, _, buffer) = makeCenter { _, _, _, _ in
            searches += 1
            return NoSearch()
        }
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.whereUsed, workbenchID: project.id)
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(searches, 0)
        XCTAssertFalse(try XCTUnwrap(ai.calls.first?.systemPrompt).contains("Usages of"))
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
    }

    /// Quitting the app reaps a running usage search (ruling R34).
    func testQuitReapsTheUsageSearch() async throws {
        let stub = try CodeCLIStub()
        defer { stub.remove() }
        let (center, _, buffer) = makeCenter(startSearch: stubStarter(stub))
        center.selectionChanged(selection(buffer, "load", CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 17)),
                                workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.whereUsed, workbenchID: project.id)
        let running = await eventually { !stub.startedPIDs.isEmpty }
        XCTAssertTrue(running)
        let codeIndex = CodeIndexCenter { nil }
        AppState.stopCodeNavigationChildren(
            index: codeIndex, openQuickly: OpenQuicklyCenter(codeIndex: codeIndex), navigation: CodeNavigationCenter(codeIndex: codeIndex),
            usages: CodeUsagesCenter(defaults: defaults), questions: center)
        await stub.assertAllGroupsReaped()
        XCTAssertEqual(center.sessions[project.id]?.isSearchingUsages, false)
        XCTAssertTrue(ai.calls.isEmpty, "a stopped search sends nothing")
    }

    // MARK: Fixes of the Where-used turn (Task 11 review)

    /// A search the test finishes by hand.
    @MainActor
    private final class HeldSearch {
        var onMatch: (@MainActor (CodeSearchMatch) -> Void)?
        var onDone: (@MainActor (CodeSearchRun.Outcome) -> Void)?

        var starter: CodeSearchStarter {
            { [self] _, _, onMatch, onDone in
                self.onMatch = onMatch
                self.onDone = onDone
                return NoSearch()
            }
        }

        @MainActor
        func finish(with hits: [(String, Int)]) {
            for (path, line) in hits {
                onMatch?(CodeSearchMatch(path: path, line: line, col: 1, text: "hit", textCol: 1, before: [], after: []))
            }
            onDone?(.finished(CodeSearchDone(files: 1, matches: hits.count, truncated: false)))
        }
    }

    /// Explain on a resumed Claude session, then "Where is it used?" for
    /// `load` with the search held until the test finishes it.
    private func resumedWhereUsed(_ search: HeldSearch) async throws -> (CodeQuestionCenter, EmbeddedChatEngine) {
        let (center, _, buffer) = makeCenter(startSearch: search.starter)
        center.selectionChanged(selection(buffer, "load", CodeTextRange(startLine: 2, startCol: 13, endLine: 2, endCol: 17)),
                                workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        let engine = try XCTUnwrap(center.engine(workbenchID: project.id))
        _ = await eventually { ai.calls.count == 1 }
        ai.emit(.sessionID("s1"), .text("It loads."), .turnComplete("It loads."), .done)
        ai.finish()
        _ = await eventually { !engine.isStreaming }
        await center.quickAction(.whereUsed, workbenchID: project.id)
        XCTAssertEqual(center.sessions[project.id]?.isSearchingUsages, true)
        return (center, engine)
    }

    /// Retry of a failed resumed Where-used turn sends the usages again:
    /// they are kept until a turn carrying them completes.
    func testRetryOfAResumedWhereUsedTurnKeepsTheUsages() async throws {
        let search = HeldSearch()
        let (center, engine) = try await resumedWhereUsed(search)
        search.finish(with: [("a.swift", 1)])
        _ = await eventually { ai.calls.count == 2 }
        XCTAssertTrue(ai.calls[1].prompt.contains("- a.swift:1: hit"), ai.calls[1].prompt)
        ai.emit(.error("overloaded"))
        ai.finish()
        let failed = await eventually { engine.canRetry }
        XCTAssertTrue(failed)
        engine.retry()
        let retried = await eventually { ai.calls.count == 3 }
        XCTAssertTrue(retried)
        XCTAssertEqual(ai.calls[2].sessionID, "s1")
        XCTAssertTrue(ai.calls[2].prompt.contains("- a.swift:1: hit"), "the retry carries the usages: \(ai.calls[2].prompt)")
        await reply("At a.swift:1.", after: 3, engine: engine)
        await center.ask("Thanks", workbenchID: project.id)
        await reply("ok", after: 4, engine: engine)
        XCTAssertEqual(ai.calls[3].prompt, "Thanks", "a completed turn used them up")
    }

    /// A follow-up the owner sends from the composer while the search runs
    /// wins; the Where-used question is not sent and its usages never ride
    /// the next, unrelated turn.
    func testAFollowUpDuringTheUsageSearchDoesNotCarryTheUsages() async throws {
        let search = HeldSearch()
        let (center, engine) = try await resumedWhereUsed(search)
        XCTAssertTrue(engine.send("Is it thread-safe?"))
        _ = await eventually { ai.calls.count == 2 }
        search.finish(with: [("a.swift", 1)])
        _ = await eventually { center.sessions[project.id]?.notice != nil }
        XCTAssertEqual(center.sessions[project.id]?.notice, "Wait for the answer to finish, then ask again.")
        XCTAssertEqual(ai.calls[1].prompt, "Is it thread-safe?")
        // That turn fails: no completed turn clears anything for the next.
        ai.emit(.error("overloaded"))
        ai.finish()
        _ = await eventually { engine.canRetry }
        await center.ask("Thanks", workbenchID: project.id)
        await reply("ok", after: 3, engine: engine)
        XCTAssertEqual(ai.calls[2].prompt, "Thanks", "no usages leak into an unrelated turn")
        XCTAssertNil(center.sessions[project.id]?.context.usages, "the unsent question's usages are rolled back")
    }

    // MARK: One owner per engine

    /// The popover and the Questions tab show the same conversation: the
    /// engine's turn-finished effect (the suggested change) runs once, and
    /// an engine made again after a release gets its owner again.
    func testTwoSurfacesOnOneConversationApplyATurnOnce() async throws {
        let (center, _, buffer) = makeCenter()
        center.selectionChanged(selection(buffer, "load(config)", loadRange), workbenchID: project.id)
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.suggestChange, workbenchID: project.id)
        let popoverEngine = try XCTUnwrap(center.engine(workbenchID: project.id))
        let conversationID = try XCTUnwrap(center.sessions[project.id]?.conversationID)
        center.reloadQuestionList(workbenchID: project.id)
        let item = try XCTUnwrap(center.questionLists[project.id]?.first)
        center.openQuestion(item, project: project, root: root)
        let ref = try XCTUnwrap(center.questionRef(conversationID))
        for _ in 0 ..< 3 {  // body passes of both surfaces
            XCTAssertTrue(center.engine(for: ref) === popoverEngine, "one engine")
            _ = center.engine(workbenchID: project.id)
        }
        await reply("```wt-edit\nload(config, default: .standard)\n```", after: 1, engine: popoverEngine)
        XCTAssertEqual(page.proposals.count, 1, "applied once")

        center.embeddedChats?.release(popoverEngine.spec.key)
        let again = try XCTUnwrap(center.engine(for: ref))
        XCTAssertFalse(again === popoverEngine)
        await center.ask("Shorter?", workbenchID: project.id)
        await reply("```wt-edit\nload(.standard)\n```", after: 2, engine: again)
        XCTAssertEqual(page.proposals.count, 2, "the new engine has its owner")
    }

    // MARK: Pin to inspector

    /// Pin moves the open conversation into the inspector's Questions tab:
    /// the same engine keeps answering, no second turn starts.
    func testPinMovesThePopoverConversationIntoTheInspector() async throws {
        let (center, _, buffer) = makeCenter()
        let usages = CodeUsagesCenter(defaults: defaults)
        center.usages = usages
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        let engine = try XCTUnwrap(center.engine(workbenchID: project.id))
        let conversationID = try XCTUnwrap(center.sessions[project.id]?.conversationID)
        _ = await eventually { ai.calls.count == 1 }
        center.pinToInspector(workbenchID: project.id)
        XCTAssertNil(center.sessions[project.id], "the popover goes")
        XCTAssertEqual(page.closed, 1)
        XCTAssertEqual(center.inspectorQuestions[project.id], conversationID)
        XCTAssertTrue(usages.isInspectorShown(workbenchID: project.id))
        XCTAssertEqual(usages.inspectorTab(workbenchID: project.id), .questions)
        let relaunched = CodeUsagesCenter(defaults: defaults)
        XCTAssertTrue(relaunched.isInspectorShown(workbenchID: project.id), "a pinned question reopens the inspector")
        XCTAssertEqual(relaunched.inspectorTab(workbenchID: project.id), .questions)
        let ref = try XCTUnwrap(center.questionRef(conversationID))
        XCTAssertTrue(center.engine(for: ref) === engine, "the same engine")
        XCTAssertTrue(engine.isStreaming, "the answer keeps streaming")
        await reply("It loads the config.", after: 1, engine: engine)
        XCTAssertEqual(ai.calls.count, 1, "no second turn")
        XCTAssertEqual(center.modelChoice(conversationID: conversationID), .init(provider: .claude, model: ""))
    }

    // MARK: Open Quickly (spec §9.3)

    /// ⌘↩ with a file open: the question is about the open file at the
    /// cursor (no selection), stored as `<wb>:<path>:<line>`.
    func testOpenQuicklyQuestionNamesTheOpenFileAtTheCursor() async throws {
        let (center, vm, buffer) = makeCenter()
        await vm.openFile(at: OpenQuicklyTarget(path: "Sources/App.swift", line: 2, col: 1), root: root, beside: false)
        _ = await eventually { buffer.state == .loaded }
        vm.codeFiles.cursorMoved(CodeNavLocation(path: "Sources/App.swift", line: 2, col: 5), root: root)
        guard case let .started(conversationID) = await center.askFromOpenQuickly("  Why load here? ", project: project, root: root) else {
            return XCTFail("not started")
        }
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(ai.calls[0].prompt, "Why load here?")
        XCTAssertNil(ai.calls[0].toolMode, "draft-only (AGENT-04)")
        let system = try XCTUnwrap(ai.calls[0].systemPrompt)
        XCTAssertTrue(system.contains("File: Sources/App.swift"), system)
        XCTAssertTrue(system.contains("Cursor line: 2"), system)
        XCTAssertTrue(system.contains("let value = load(config)"), system)
        let contextID = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT context_id FROM chat_conversations WHERE id = ? AND context_type = 'code_question'",
                                arguments: [conversationID])
        }
        XCTAssertEqual(contextID, "\(project.id):Sources/App.swift:2")
        XCTAssertNil(center.sessions[project.id], "no popover")
        let engine = try XCTUnwrap(center.engine(for: try XCTUnwrap(center.questionRef(conversationID))))
        ai.emit(.sessionID("s1"))
        await reply("It reads the config.", after: 1, engine: engine)
        engine.draft = "And then?"
        XCTAssertTrue(engine.sendDraft(), "↩ follows up in the card")
        _ = await eventually { ai.calls.count == 2 }
        XCTAssertEqual(ai.calls[1].sessionID, "s1", "the same conversation")
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
    }

    /// With no file open the context names the folder only: `<wb>::0`.
    func testOpenQuicklyQuestionWithNoFileOpen() async throws {
        let (center, _, _) = makeCenter()
        guard case let .started(conversationID) = await center.askFromOpenQuickly("What is this repo?", project: project, root: root) else {
            return XCTFail("not started")
        }
        _ = await eventually { ai.calls.count == 1 }
        let system = try XCTUnwrap(ai.calls.first?.systemPrompt)
        XCTAssertTrue(system.contains("No file was open"), system)
        let contextID = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT context_id FROM chat_conversations WHERE id = ?", arguments: [conversationID])
        }
        XCTAssertEqual(contextID, "\(project.id)::0")
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
        let blank = await center.askFromOpenQuickly("   ", project: project, root: root)
        XCTAssertEqual(blank, .failed("Type a question first."))
    }

    // MARK: Questions tab (spec §9.4)

    /// This workbench's questions only, newest first; Delete removes the
    /// conversation, its messages and its engine, and closes what shows it.
    func testQuestionsListAndDelete() async throws {
        let (center, _, _) = makeCenter()
        try await pool.write { db in
            _ = try ChatConversationQueries.create(db, title: "x", contextType: "code_question", contextID: "90:a.swift:1")
        }
        guard case let .started(first) = await center.askFromOpenQuickly("First?", project: project, root: root) else { return XCTFail("first") }
        let firstEngine = try XCTUnwrap(center.engine(for: try XCTUnwrap(center.questionRef(first))))
        await reply("one", after: 1, engine: firstEngine)
        try await pool.write { db in
            try db.execute(sql: "UPDATE chat_conversations SET created_at = created_at - 60 WHERE id = ?", arguments: [first])
        }
        guard case let .started(second) = await center.askFromOpenQuickly("Second?", project: project, root: root) else { return XCTFail("second") }
        await reply("two", after: 2, engine: center.engine(for: try XCTUnwrap(center.questionRef(second))))
        center.reloadQuestionList(workbenchID: project.id)
        let items = try XCTUnwrap(center.questionLists[project.id])
        XCTAssertEqual(items.map(\.conversationID), [second, first], "newest first, this workbench only")
        XCTAssertEqual(items.map(\.firstQuestion), ["Second?", "First?"])

        center.openQuestion(items[1], project: project, root: root)
        XCTAssertEqual(center.inspectorQuestions[project.id], first)
        let key = firstEngine.spec.key
        await center.deleteQuestion(try XCTUnwrap(center.questionRef(first)))
        XCTAssertNil(center.inspectorQuestions[project.id], "the inspector goes back to the list")
        XCTAssertNil(center.embeddedChats?.loaded(key), "its engine is dropped")
        XCTAssertEqual(center.questionLists[project.id]?.map(\.conversationID), [second])
        let left = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?", arguments: [first])
        }
        XCTAssertEqual(left, 0)
    }

    /// The tab's list follows the database while it shows: a question
    /// asked and one deleted reach it with no reload; a hidden tab's list
    /// stays as it was.
    func testTheShownListFollowsQuestionsAskedAndDeleted() async throws {
        let (center, _, _) = makeCenter()
        let watching = Task { await center.observeQuestionList(workbenchID: project.id) }
        let empty = await eventually { center.questionLists[project.id]?.isEmpty == true }
        XCTAssertTrue(empty)
        guard case let .started(first) = await center.askFromOpenQuickly("First?", project: project, root: root) else { return XCTFail("first") }
        let listed = await eventually { center.questionLists[project.id]?.map(\.firstQuestion) == ["First?"] }
        XCTAssertTrue(listed)
        await reply("one", after: 1, engine: center.engine(for: try XCTUnwrap(center.questionRef(first))))
        try await pool.write { db in _ = try CodeQuestionList.delete(db, conversationID: first) }
        let gone = await eventually { center.questionLists[project.id]?.isEmpty == true }
        XCTAssertTrue(gone, "a delete reaches the list too")

        watching.cancel()
        await watching.value
        guard case .started = await center.askFromOpenQuickly("Second?", project: project, root: root) else { return XCTFail("second") }
        XCTAssertEqual(center.questionLists[project.id]?.isEmpty, true, "a list no tab shows is not followed")
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
    }

    /// An action's error (a model change on a question deleted meanwhile)
    /// stays while new rows reach the observed list.
    func testAnActionErrorOutlivesTheListUpdates() async throws {
        let (center, _, _) = makeCenter()
        let watching = Task { await center.observeQuestionList(workbenchID: project.id) }
        defer { watching.cancel() }
        guard case let .started(first) = await center.askFromOpenQuickly("First?", project: project, root: root) else { return XCTFail("first") }
        await reply("one", after: 1, engine: center.engine(for: try XCTUnwrap(center.questionRef(first))))
        try await pool.write { db in _ = try CodeQuestionList.delete(db, conversationID: first) }
        await center.setModelChoice(.init(provider: .codex, model: ""), conversationID: first)
        let error = try XCTUnwrap(center.questionListErrors[project.id])
        guard case .started = await center.askFromOpenQuickly("Second?", project: project, root: root) else { return XCTFail("second") }
        let listed = await eventually { center.questionLists[project.id]?.map(\.firstQuestion) == ["Second?"] }
        XCTAssertTrue(listed)
        XCTAssertEqual(center.questionListErrors[project.id], error, "a list update does not hide it")
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
    }

    /// A question reopened after a restart (no context in memory) rebuilds
    /// its context from the file around its line (ruling R41).
    func testAReopenedQuestionRebuildsItsContextFromTheFile() async throws {
        let (center, _, _) = makeCenter()
        let contextID = "\(project.id):Sources/App.swift:3"
        let conversationID = try await pool.write { db in
            let id = try ChatConversationQueries.create(db, title: "x", contextType: "code_question", contextID: contextID).id
            // An asked question (the list shows only those, board #670).
            try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'user', 'Why?', 1)",
                           arguments: [id])
            return id
        }
        center.reloadQuestionList(workbenchID: project.id)
        center.openQuestion(try XCTUnwrap(center.questionLists[project.id]?.first), project: project, root: root)
        let ref = try XCTUnwrap(center.questionRef(conversationID))
        let rebuilt = await eventually { center.hasContext(conversationID: conversationID) }
        XCTAssertTrue(rebuilt)
        let engine = try XCTUnwrap(center.engine(for: ref))
        XCTAssertTrue(engine.send("Again?"))
        _ = await eventually { ai.calls.count == 1 }
        let system = try XCTUnwrap(ai.calls.first?.systemPrompt)
        XCTAssertTrue(system.contains("Cursor line: 3"), system)
        XCTAssertTrue(system.contains("print(value)"), system)
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
    }

    /// A deleted workbench takes its questions' state along (PROJ-02): the
    /// popover closes, the engines stop, the tab forgets the list; another
    /// workbench's question stays.
    func testARemovedWorkbenchForgetsItsQuestions() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        let popoverID = try XCTUnwrap(center.sessions[project.id]?.conversationID)
        let popoverKey = try XCTUnwrap(center.engine(workbenchID: project.id)).spec.key
        await reply("ok", after: 1, engine: center.engine(workbenchID: project.id))
        let other = Workbench(row: Row(["id": 10, "name": "other", "folder_path": folder.path]))
        guard case let .started(otherID) = await center.askFromOpenQuickly("Theirs?", project: other, root: other.mainCodeRoot) else {
            return XCTFail("other")
        }
        await reply("theirs", after: 2, engine: center.engine(for: try XCTUnwrap(center.questionRef(otherID))))
        center.reloadQuestionList(workbenchID: project.id)
        center.openQuestion(try XCTUnwrap(center.questionLists[project.id]?.first), project: project, root: root)

        center.workbenchRemoved(project.id)

        XCTAssertNil(center.sessions[project.id])
        XCTAssertEqual(page.closed, 1, "the popover closes")
        XCTAssertNil(center.questionRef(popoverID))
        XCTAssertNil(center.embeddedChats?.loaded(popoverKey), "its engine is dropped")
        XCTAssertNil(center.inspectorQuestions[project.id])
        XCTAssertNil(center.questionLists[project.id])
        XCTAssertNotNil(center.questionRef(otherID), "another workbench's question stays")
    }

    /// Hand to Claude Code from the popover: refused with a beep (the
    /// popover kept) before the first question and while the answer
    /// streams; once it is done the popover closes and the sheet gets the
    /// conversation.
    func testThePopoversHandOffWaitsForTheAnswerThenClosesIt() async throws {
        let (center, _, buffer) = makeCenter()
        let handoff = CodeHandoffCenter {}
        handoff.dbPool = pool
        center.handoff = handoff
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        center.handToClaude(workbenchID: project.id)
        XCTAssertEqual(beeps, 1, "no question yet")
        XCTAssertNotNil(center.sessions[project.id])

        await center.quickAction(.explain, workbenchID: project.id)
        let engine = center.engine(workbenchID: project.id)
        _ = await eventually { ai.calls.count == 1 }
        center.handToClaude(workbenchID: project.id)
        XCTAssertEqual(beeps, 2, "the answer is still coming")
        XCTAssertEqual(page.closed, 0)
        XCTAssertNotNil(center.sessions[project.id])

        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
        _ = await eventually { engine?.isStreaming == false }
        center.handToClaude(workbenchID: project.id)
        XCTAssertNil(center.sessions[project.id], "the popover closes first")
        XCTAssertEqual(page.closed, 1)
        let presented = await eventually { handoff.requests[project.id] != nil }
        XCTAssertTrue(presented)
        XCTAssertEqual(beeps, 2)
    }

    /// The Questions tab's hand-off closes nothing; with no hand-off center
    /// it beeps.
    func testTheTabsHandOffClosesNothing() async throws {
        let (center, _, _) = makeCenter()
        guard case let .started(id) = await center.askFromOpenQuickly("Why?", project: project, root: root) else { return XCTFail("start") }
        let question = try XCTUnwrap(center.questionRef(id))
        await reply("Because.", after: 1, engine: center.engine(for: question))
        center.handToClaude(question)
        XCTAssertEqual(beeps, 1, "no hand-off center")
        let handoff = CodeHandoffCenter {}
        handoff.dbPool = pool
        center.handoff = handoff
        center.handToClaude(question)
        let presented = await eventually { handoff.requests[project.id] != nil }
        XCTAssertTrue(presented)
        XCTAssertEqual(page.closed, 0)
        XCTAssertEqual(beeps, 1)
    }

    /// Deleting the question the popover shows closes the popover.
    func testDeletingThePopoversQuestionClosesIt() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        await center.quickAction(.explain, workbenchID: project.id)
        let conversationID = try XCTUnwrap(center.sessions[project.id]?.conversationID)
        await reply("ok", after: 1, engine: center.engine(workbenchID: project.id))
        await center.deleteQuestion(try XCTUnwrap(center.questionRef(conversationID)))
        XCTAssertNil(center.sessions[project.id])
        XCTAssertEqual(page.closed, 1)
    }

    // MARK: Writes off the main thread (board #670)

    private func conversationCount() async throws -> Int {
        try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations") ?? 0 }
    }

    /// Polls the database until `count` conversations are left (5 s).
    private func waitForConversations(_ count: Int) async throws -> Int {
        var left = try await conversationCount()
        let start = ContinuousClock.now
        while left != count, ContinuousClock.now - start < .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
            left = try await conversationCount()
        }
        return left
    }

    /// While the first question's conversation waits for the writer, the
    /// popover takes no second question or quick action: one conversation,
    /// one turn.
    func testASecondAskWhileTheConversationIsWrittenDoesNothing() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        let held = HeldWriter(pool)
        defer { held.release() }
        let first = Task { await center.ask("Why?", workbenchID: project.id) }
        let starting = await eventually { center.sessions[self.project.id]?.isStarting == true }
        XCTAssertTrue(starting, "the main actor runs while the write waits")
        let second = await boundedValue(Task { await center.ask("Why again?", workbenchID: project.id) })
        XCTAssertEqual(second, false, "a second ask while the first is written does nothing (nil = it waited)")
        let quick = await boundedValue(Task { await center.quickAction(.explain, workbenchID: project.id) })
        XCTAssertNotNil(quick, "a quick action meanwhile returns at once")
        held.release()
        let sent = await boundedValue(first)
        XCTAssertEqual(sent, true)
        await reply("Because.", after: 1, engine: center.engine(workbenchID: project.id))
        XCTAssertEqual(ai.calls.map(\.prompt), ["Why?"])
        let count = try await conversationCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(center.sessions[project.id]?.isStarting, false)
    }

    /// The popover closes while its conversation is written: nothing is
    /// sent and the row goes again, so no empty question stays behind.
    func testAPopoverClosedWhileItsConversationIsWrittenLeavesNothing() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        let held = HeldWriter(pool)
        defer { held.release() }
        let asking = Task { await center.ask("Why?", workbenchID: project.id) }
        let starting = await eventually { center.sessions[self.project.id]?.isStarting == true }
        XCTAssertTrue(starting)
        center.closeQuestion(workbenchID: project.id)
        held.release()
        let sent = await boundedValue(asking)
        XCTAssertEqual(sent, false)
        let left = try await waitForConversations(0)
        XCTAssertEqual(left, 0, "the closed popover's conversation is removed")
        XCTAssertTrue(ai.calls.isEmpty)
    }

    /// A conversation that cannot be written changes nothing but the
    /// notice: the draft stays, the popover can ask again.
    func testAFailedConversationWriteKeepsTheDraftAndSaysSo() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_conversations BEFORE INSERT ON chat_conversations
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        center.setDraft("Why?", workbenchID: project.id)
        let sent = await center.ask("Why?", workbenchID: project.id)
        XCTAssertFalse(sent)
        let session = try XCTUnwrap(center.sessions[project.id])
        XCTAssertEqual(session.draft, "Why?", "the draft is kept")
        XCTAssertNil(session.conversationID)
        XCTAssertFalse(session.isStarting)
        XCTAssertTrue(session.notice?.hasPrefix("Couldn't start the question:") == true, session.notice ?? "")
        XCTAssertTrue(ai.calls.isEmpty)

        try await pool.write { try $0.execute(sql: "DROP TRIGGER refuse_conversations") }
        let retried = await center.ask("Why?", workbenchID: project.id)
        XCTAssertTrue(retried)
        XCTAssertNil(center.sessions[project.id]?.notice)
        await reply("Because.", after: 1, engine: center.engine(workbenchID: project.id))
    }

    /// A model pick waits for the writer with the shown pick unchanged; a
    /// second pick meanwhile is dropped, so an older pick never lands last.
    func testAModelPickChangesTheShownPickOnlyOnceStoredAndOneAtATime() async throws {
        let (center, _, _) = makeCenter()
        guard case let .started(id) = await center.askFromOpenQuickly("Why?", project: project, root: root) else {
            return XCTFail("start")
        }
        await reply("ok", after: 1, engine: center.engine(for: try XCTUnwrap(center.questionRef(id))))
        let held = HeldWriter(pool)
        defer { held.release() }
        let picking = Task { await center.setModelChoice(.init(provider: .codex, model: ""), conversationID: id) }
        let storing = await eventually { center.storingChoices.contains(id) }
        XCTAssertTrue(storing)
        XCTAssertEqual(center.modelChoice(conversationID: id).provider, .claude, "unchanged until stored")
        let dropped = await boundedValue(Task { await center.setModelChoice(.init(provider: .ollama, model: ""), conversationID: id) })
        XCTAssertNotNil(dropped, "a second pick meanwhile returns at once")
        held.release()
        let stored = await boundedValue(picking)
        XCTAssertNotNil(stored)
        XCTAssertEqual(center.modelChoice(conversationID: id).provider, .codex)
        let provider = try await pool.read {
            try String.fetchOne($0, sql: "SELECT provider FROM chat_conversations WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(provider, "codex")
    }

    /// A delete waiting for the writer keeps the question shown and takes
    /// nothing more for it; a second Delete meanwhile does nothing.
    func testADeleteChangesTheListOnlyOnceTheRowIsGone() async throws {
        let (center, _, _) = makeCenter()
        guard case let .started(id) = await center.askFromOpenQuickly("Why?", project: project, root: root) else {
            return XCTFail("start")
        }
        await reply("ok", after: 1, engine: center.engine(for: try XCTUnwrap(center.questionRef(id))))
        center.reloadQuestionList(workbenchID: project.id)
        let question = try XCTUnwrap(center.questionRef(id))
        let held = HeldWriter(pool)
        defer { held.release() }
        let deleting = Task { await center.deleteQuestion(question) }
        let pending = await eventually { center.isDeleting(id) }
        XCTAssertTrue(pending)
        XCTAssertEqual(center.questionLists[project.id]?.map(\.conversationID), [id], "still listed while it waits")
        let second = await boundedValue(Task { await center.deleteQuestion(question) })
        XCTAssertNotNil(second, "a second Delete meanwhile returns at once")
        let pick = await boundedValue(Task { await center.setModelChoice(.init(provider: .codex, model: ""), conversationID: id) })
        XCTAssertNotNil(pick, "no pick for a question being deleted")
        XCTAssertFalse(center.storingChoices.contains(id))
        held.release()
        let done = await boundedValue(deleting)
        XCTAssertNotNil(done)
        XCTAssertFalse(center.isDeleting(id))
        XCTAssertEqual(center.questionLists[project.id]?.isEmpty, true)
        XCTAssertNil(center.questionRef(id))
        let count = try await conversationCount()
        XCTAssertEqual(count, 0)
    }

    /// The first list load deletes questions that never got a message and
    /// are older than the start window; a newer empty one stays, unlisted.
    func testTheFirstListLoadRemovesOldEmptyQuestions() async throws {
        let (center, _, _) = makeCenter()
        now = Date()
        let created = now.timeIntervalSince1970
        let old = created - CodeQuestionList.emptyQuestionAge - 60
        let rows = [("\(project.id):a.swift:1", old), ("\(project.id):b.swift:2", created)]
        try await pool.write { db in
            for (contextID, at) in rows {
                try db.execute(sql: """
                    INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                    VALUES ('t', ?, ?, ?, ?)
                    """, arguments: [CodeQuestionList.contextType, contextID, at, at])
            }
        }
        center.reloadQuestionList(workbenchID: project.id)
        XCTAssertEqual(center.questionLists[project.id]?.isEmpty, true, "a question with no message is not listed")
        let left = try await waitForConversations(1)
        XCTAssertEqual(left, 1, "only the old empty question goes")
        let kept = try await pool.read { try String.fetchOne($0, sql: "SELECT context_id FROM chat_conversations") }
        XCTAssertEqual(kept, "\(project.id):b.swift:2")
    }

    /// Text typed into the field while the first question's row is written
    /// stays there; only the submitted draft is cleared.
    func testTextTypedWhileTheConversationIsWrittenStays() async throws {
        let (center, _, buffer) = makeCenter()
        await center.askAI(bufferID: buffer.id, project: project, root: root)
        center.setDraft("Why?", workbenchID: project.id)
        let held = HeldWriter(pool)
        defer { held.release() }
        let asking = Task { await center.ask("Why?", workbenchID: project.id) }
        let starting = await eventually { center.sessions[self.project.id]?.isStarting == true }
        XCTAssertTrue(starting)
        center.setDraft("Why? And then", workbenchID: project.id)
        held.release()
        let sent = await boundedValue(asking)
        XCTAssertEqual(sent, true)
        XCTAssertEqual(center.sessions[project.id]?.draft, "Why? And then")
        await reply("Because.", after: 1, engine: center.engine(workbenchID: project.id))
    }

    /// The cleanup never takes a conversation a surface still holds (its
    /// turn may wait for a stream slot), however old and empty.
    func testTheCleanupKeepsAConversationTheCenterHolds() async throws {
        let (center, _, _) = makeCenter()
        now = Date()
        let old = now.timeIntervalSince1970 - CodeQuestionList.emptyQuestionAge - 60
        let contextIDs = ["\(project.id):Sources/App.swift:1", "\(project.id):Sources/App.swift:2"]
        let ids = try await pool.write { db in
            try contextIDs.map { contextID in
                try db.execute(sql: """
                    INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                    VALUES ('t', ?, ?, ?, ?)
                    """, arguments: [CodeQuestionList.contextType, contextID, old, old])
                return db.lastInsertedRowID
            }
        }
        let held = ids[0]
        center.openQuestion(CodeQuestionListItem(conversationID: held, path: "Sources/App.swift", line: 1, firstQuestion: nil,
                                                 createdAt: Date(timeIntervalSince1970: old)),
                            project: project, root: root)
        center.reloadQuestionList(workbenchID: project.id)
        let left = try await waitForConversations(1)
        XCTAssertEqual(left, 1, "the one no surface holds goes")
        let kept = try await pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM chat_conversations") }
        XCTAssertEqual(kept, held)
    }
}

private final class NoSearch: CodeSearchCancelling {
    func cancel() {}
}
