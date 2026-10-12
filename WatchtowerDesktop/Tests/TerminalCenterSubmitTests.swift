import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Spec 2026-10-12 §8 (board #399): answers, comments and hand-offs typed
/// into a Codex session by its `AgentInputProfile`; PROJ-12's gates hold for
/// it unchanged. The Codex rows run on stubbed launch args (no real `codex`).
@MainActor
final class TerminalCenterSubmitTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var slept: [Duration] = []
    /// Runs inside each pause (the owner typing meanwhile).
    private var onSleep: (() -> Void)?

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "TerminalCenterSubmitTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt submit \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        slept = []
        onSleep = nil
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession(pid: 0)
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { _, _ in }, isAlive: { _ in false },
                sleep: { [weak self] step in
                    self?.slept.append(step)
                    self?.onSleep?()
                }
            )
        )
        center.shell = { "/bin/zsh" }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Helpers

    /// A workbench with one running Codex session, and an open question ask
    /// filed from it.
    private func runningCodexSession() async throws -> (project: Int64, session: TerminalSession, ask: Int64) {
        let acme = folder.path
        let seeded = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .codex, title: "codex", folderPath: acme))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            return (p, s, ask)
        }
        center.start(seeded.1, fresh: true, codex: CodexLaunchArgs(binary: "/Users/example/bin/codex", pathPrepend: "", args: []))
        return seeded
    }

    /// Its sessions' hooks count as having reported this run and every
    /// state read as fresh, so an answer may be submitted.
    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        return vm
    }

    private func pickedAsk(_ vm: WorkbenchesViewModel, project: Int64, id: Int64) async throws -> OwnerAsk {
        await vm.asks.load(projectID: project)
        vm.asks.drafts.update(id) { $0.picks["a"] = .init(labels: ["Yes"]) }
        return try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id })
    }

    private func paste(_ text: String) -> [UInt8] {
        [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array(text.utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    }

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    // MARK: - The session's profile

    /// The profile follows the row's agent; a shell, or a session this
    /// center never started, types as Claude Code always did.
    func testTheProfileFollowsTheRowsAgent() async throws {
        let acme = folder.path
        let (codex, shell) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            return (try TerminalSessionQueries.create(d, .init(projectID: p, kind: .codex, title: "c", folderPath: acme)),
                    try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "z", folderPath: acme)))
        }
        center.start(codex, fresh: true)
        center.start(shell, fresh: true)

        XCTAssertEqual(center.agent(of: codex.id), .codex)
        XCTAssertEqual(center.inputProfile(codex.id), .codex)
        XCTAssertNil(center.agent(of: shell.id))
        XCTAssertEqual(center.inputProfile(shell.id), .claude)
        XCTAssertEqual(center.inputProfile(9999), .claude, "an unknown session")
        XCTAssertEqual(TerminalCenter.submitDelay, AgentInputProfile.claude.pasteSettle)
        XCTAssertEqual(TerminalCenter.answerSubmitDelay, AgentInputProfile.claude.submitSettle)
    }

    // MARK: - Delivery

    /// A hand-off into Codex: one bracketed paste, the profile's pause, then
    /// its CR as a write of its own.
    func testCodexSubmitIsBracketedPasteThenCR() async throws {
        let (_, s, _) = try await runningCodexSession()

        let delivery = await center.submitPrompt("Fix the flaky test", sessionID: s.id) { true }

        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(typed, [paste("Fix the flaky test"), AgentInputProfile.codex.submit])
        XCTAssertEqual(slept, [AgentInputProfile.codex.pasteSettle])
    }

    /// A multi-line hand-off keeps its line breaks inside the one paste and
    /// goes as one prompt (one CR); an answer's line breaks are dropped.
    func testCodexMultilineAnswerOnePrompt() async throws {
        let (_, s, _) = try await runningCodexSession()

        let handOff = await center.submitPrompt("first\nsecond\r\nthird", sessionID: s.id) { true }
        let answer = await center.submitPrompt("line one\nline two", sessionID: s.id, keepingLineBreaks: false,
                                               delay: center.inputProfile(s.id).submitSettle) { true }

        XCTAssertEqual(handOff, .submitted)
        XCTAssertEqual(answer, .submitted)
        XCTAssertEqual(typed, [paste("first\nsecond\nthird"), [0x0D], paste("line oneline two"), [0x0D]])
        XCTAssertEqual(slept, [AgentInputProfile.codex.pasteSettle, AgentInputProfile.codex.submitSettle])
    }

    // MARK: - PROJ-12 on Codex

    /// PROJ-12: while Codex waits on an approval nothing is typed; the line
    /// goes, pasted and submitted, once it is answered. The notes name Codex.
    func testProj12_CodexAnswerHeldWhileApproval() async throws {
        let (p, s, askID) = try await runningCodexSession()
        let vm = makeVM()
        var approval = true
        vm.asks.needsApproval = { id in id == s.id && approval }
        center.inputAnswersDialog = { id in id == s.id && approval }
        let ask = try await pickedAsk(vm, project: p, id: askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .held)
        XCTAssertTrue(typed.isEmpty, "nothing reaches the approval prompt")
        let held = try XCTUnwrap(vm.asks.answerNotices[askID])
        XCTAssertEqual(vm.asks.noticeText(held, ask: ask),
                       "Answer saved — it goes to Codex once the permission prompt is resolved")

        approval = false
        await vm.asks.deliverHeldAnswers()

        XCTAssertEqual(typed.count, 2, "one paste, then its CR")
        XCTAssertEqual(typed.last, AgentInputProfile.codex.submit)
        XCTAssertEqual(slept, [AgentInputProfile.codex.submitSettle], "an answer's pause")
    }

    /// PROJ-12: until Codex's hooks report this run nothing vouches that no
    /// approval prompt is up, so the line is only pasted.
    func testProj12_CodexAnswerNotSubmittedBeforeHooksReported() async throws {
        let (p, s, askID) = try await runningCodexSession()
        let vm = makeVM()
        vm.asks.hasHookState = { _ in false }
        let ask = try await pickedAsk(vm, project: p, id: askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .typed)
        XCTAssertEqual(typed.count, 1)
        XCTAssertFalse(typed[0].contains(0x0D))
        XCTAssertEqual(center.answerHints[s.id], .typed)
    }

    // MARK: - Owner-draft tracking

    /// The owner's Ctrl+J line break in Codex's composer is a draft, so the
    /// next line is only pasted; their plain Return submits it and the next
    /// line gets its CR again.
    func testCodexDraftTrackingUsesCodexNewline() async throws {
        let (_, s, _) = try await runningCodexSession()
        processes[0].onOwnerInput?(Array("half".utf8) + [0x0A])

        let overDraft = await center.submitPrompt("x", sessionID: s.id) { true }
        XCTAssertEqual(overDraft, .pasted)
        XCTAssertTrue(slept.isEmpty, "no Return to wait for")

        processes[0].onOwnerInput?([0x0D])
        let clean = await center.submitPrompt("y", sessionID: s.id) { true }
        XCTAssertEqual(clean, .submitted)
        XCTAssertEqual(typed, [paste("x"), paste("y"), [0x0D]])
    }

    /// The keys the capture saw, read under each profile: Codex's newline
    /// and the line breaks every agent shares are drafts; only a plain CR
    /// submits. `\` then Return stays a draft in Codex too (fail safe).
    func testIsSubmitPerProfile() {
        let drafts: [(String, [UInt8])] = [
            ("Ctrl+J", Array("a".utf8) + [0x0A]),
            ("Option+Return", Array("a".utf8) + [0x1B, 0x0D]),
            ("kitty Shift+Return", Array("a".utf8) + Array("\u{1B}[13;2u".utf8)),
            ("backslash Return", Array("a\\".utf8) + [0x0D]),
            ("text", Array("a".utf8)),
            ("Ctrl+C", [0x03]),
            ("empty", [])
        ]
        for profile in [AgentInputProfile.claude, .codex] {
            for (name, bytes) in drafts {
                XCTAssertFalse(TerminalCenter.isSubmit(bytes, backslashBefore: false, profile: profile), name)
            }
            XCTAssertTrue(TerminalCenter.isSubmit(Array("a".utf8) + [0x0D], backslashBefore: false, profile: profile))
            XCTAssertTrue(TerminalCenter.isSubmit([0x0D], backslashBefore: false, profile: profile))
            XCTAssertFalse(TerminalCenter.isSubmit([0x0D], backslashBefore: true, profile: profile), "after a `\\` typed earlier")
        }
    }

    // MARK: - Strings

    /// The notes name the agent the line went to: Codex by its name; Claude
    /// Code's wording is unchanged.
    func testAnswerSentStringNamesCodex() async throws {
        let (p, _, askID) = try await runningCodexSession()
        let vm = makeVM()
        let ask = try await pickedAsk(vm, project: p, id: askID)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        let notice = try XCTUnwrap(vm.asks.answerNotices[askID])
        XCTAssertEqual(vm.asks.noticeText(notice, ask: ask), "Answer sent to Codex")
        XCTAssertEqual(notice.text, "Answer sent to Claude", "the Claude Code wording")
        XCTAssertEqual(notice.text(agent: nil), "Answer sent to Claude", "an agent not known")
        XCTAssertEqual(OwnerAsksViewModel.sentNote(into: .codex), "Pasted into Codex — press Return to send")
        XCTAssertEqual(OwnerAsksViewModel.sentNote, "Pasted into Claude — press Return to send")
        XCTAssertEqual(OwnerAsksViewModel.sentBesideTextNote(into: .codex),
                       "Pasted into Codex next to text not sent yet — press Return to send them together")
        XCTAssertEqual(OwnerAsksViewModel.answerHeldNote,
                       "Answer saved — it goes to Claude once the permission prompt is resolved")
    }
}
