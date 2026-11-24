import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerChatText
import WatchtowerCore
import WatchtowerTestSupport

/// `WorkchatModel`: the Workchat composer's lines go through
/// `SessionLineDelivery` behind `SessionControl.lineCheck` (PROJ-16's gate,
/// no device grant at the Mac), and Stop through its interrupt guard (#711).
@MainActor
final class WorkchatModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var delivery: SessionLineDelivery!
    private var statuses: [Int64: SessionAgentStatus] = [:]
    private var clock: LinkTestClock!
    private var workbenchID: Int64 = 0
    /// The row `liveSession` made last.
    private var lastRow: TerminalSession?

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt workchat \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        statuses = [:]
        clock = LinkTestClock(Date())
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
        center.transcriptExists = { _ in true }
        delivery = SessionLineDelivery(terminalCenter: center)
        delivery.refreshStates = { true }
        let deliveryClock = try XCTUnwrap(clock)
        delivery.now = { deliveryClock.now }
        delivery.needsApproval = { [weak self] in self?.statuses[$0]?.state.kind == .needsApproval }
        delivery.hasHookState = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var typedText: String { String(bytes: processes.flatMap(\.inputs).joined(), encoding: .utf8) ?? "" }

    private func makeControl() throws -> SessionControl {
        let clock = try XCTUnwrap(clock)
        return SessionControl(
            dbPool: pool, terminalCenter: center, lineDelivery: delivery,
            status: { [weak self] in self?.statuses[$0] },
            now: { clock.now }
        )
    }

    private func makeModel(
        _ sessionID: Int64, control: (any WorkchatControl)? = nil, promptPreview: @escaping (Int64) -> String? = { _ in nil }
    ) throws -> WorkchatModel {
        let clock = try XCTUnwrap(clock)
        let control = try control ?? makeControl()
        return WorkchatModel(
            sessionID: sessionID, control: control, lineDelivery: delivery,
            attachmentStore: WorkchatAttachmentStore(root: folder.appendingPathComponent("att")), kind: { .claude },
            now: { clock.now }, promptPreview: promptPreview
        )
    }

    /// Lets one test make the permission read, the answer or the interrupt
    /// fail or wait; each call not scripted goes to the real control.
    private final class ScriptedControl: WorkchatControl {
        let base: SessionControl
        var pending: ((Int64) async throws -> SessionControl.PermissionPrompt?)?
        var answer: (() async throws -> SessionControl.PermissionAnswer)?
        var interrupt: (() async throws -> SessionControl.InterruptResult)?
        private(set) var answers = 0

        init(base: SessionControl) {
            self.base = base
        }

        func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck {
            base.lineCheck(sessionID)
        }

        func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck {
            base.workchatLineCheck(sessionID)
        }

        func isWorking(_ sessionID: Int64) -> Bool {
            base.isWorking(sessionID)
        }

        func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult {
            if let interrupt { return try await interrupt() }
            return try await base.interrupt(sessionID)
        }

        func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? {
            if let pending { return try await pending(sessionID) }
            return try await base.pendingPermission(sessionID)
        }

        func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
            -> SessionControl.PermissionAnswer {
            answers += 1
            if let answer { return try await answer() }
            return try await base.answerPermission(requestID: requestID, sessionID: sessionID, allow: allow, decidedBy: decidedBy)
        }
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "disk I/O error" }
    }

    /// A one-time suspension the test releases: the first `wait` parks
    /// until `release`; later ones pass straight through.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var reached = false

        func wait() async {
            guard !reached else { return }
            reached = true
            settle(parked: true)
            await withCheckedContinuation { continuation = $0 }
        }

        /// Whoever awaits `parked()`, and how it ended (`nil`: not yet).
        private var parkWaiter: CheckedContinuation<Bool, Never>?
        private var parkOutcome: Bool? // swiftlint:disable:this discouraged_optional_boolean

        /// True once a call parks here; false when the work that should
        /// park ends first (`ended`). No yield count and no clock bound it:
        /// one of the two always comes.
        func parked() async -> Bool {
            if let parkOutcome { return parkOutcome }
            return await withCheckedContinuation { parkWaiter = $0 }
        }

        /// The work meant to park here is over.
        func ended() { settle(parked: false) }

        private func settle(parked: Bool) {
            guard parkOutcome == nil else { return }
            parkOutcome = parked
            parkWaiter?.resume(returning: parked)
            parkWaiter = nil
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }

        /// Yields until a call parks here (bounded).
        func untilReached() async {
            for _ in 0..<1_000 where !reached { await Task.yield() }
        }
    }

    private func liveSession(kind: TerminalSession.Kind = .claude) async throws -> Int64 {
        let acme = folder.path
        let session = try await pool.write { db -> TerminalSession in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: kind, title: "Ship it", folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        workbenchID = try XCTUnwrap(session.projectID)
        lastRow = session
        // A Codex session needs its binary to start; the permission read
        // does not care whether it runs.
        guard kind == .claude else { return session.id }
        center.start(session, fresh: true)
        XCTAssertTrue(center.liveIDs.contains(session.id))
        return session.id
    }

    private func setState(_ sessionID: Int64, _ kind: SessionSwitcherPresentation.State.Kind) {
        statuses[sessionID] = SessionAgentStatus(
            sessionID: sessionID, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: kind, live: true), at: SessionAgentStatus.formatStamp(clock.now)
        )
    }

    private func owner(_ text: String, after seconds: TimeInterval) -> SessionFeedEntry {
        SessionFeedEntry(id: UUID().uuidString, kind: "owner", at: clock.now.addingTimeInterval(seconds), text: text)
    }

    // MARK: - Attachments

    func testPasteImageAddsChip() async throws {
        let model = try makeModel(try await liveSession())

        let taken = await model.attach(data: Data([1, 2]), name: "Pasted image.png")

        XCTAssertTrue(taken)
        let chip = try XCTUnwrap(model.attachments.first)
        XCTAssertLessThan(chip.id, 0)
        XCTAssertEqual(chip.name, "Pasted image.png")
        XCTAssertEqual(chip.mime, "image/png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chip.path))
        model.removeAttachment(chip.id)
        XCTAssertTrue(model.attachments.isEmpty)
    }

    /// A paste that cannot be saved says so under the field; the next
    /// attach or send clears it.
    func testFailedPasteSaveShowsAnError() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let blocker = folder.appendingPathComponent("not-a-folder")
        try Data([0]).write(to: blocker)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery,
            attachmentStore: WorkchatAttachmentStore(root: blocker), kind: { .claude }, now: { clock.now }
        )

        let taken = await model.attach(data: Data([1]), name: "Pasted image.png")

        XCTAssertFalse(taken)
        XCTAssertTrue(model.attachments.isEmpty)
        let error = try XCTUnwrap(model.attachmentError)
        XCTAssertTrue(error.hasPrefix("Could not save the pasted file"), error)

        let file = folder.appendingPathComponent("a.png")
        try Data([9]).write(to: file)
        model.attach(files: [file])
        XCTAssertNil(model.attachmentError, "the next attach clears it")

        _ = await model.attach(data: Data([1]), name: "Pasted image.png")
        XCTAssertNotNil(model.attachmentError)
        model.draft = "look"
        await model.send()
        XCTAssertNil(model.attachmentError, "a send clears it")
    }

    func testSendQuotesAndEscapesQuoteAndBackslashInPaths() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let file = folder.appendingPathComponent(#"say "hi"\x.png"#)
        model.attach(files: [file])

        await model.send()

        let escaped = file.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertEqual(model.outgoing.first?.text, "\"\(escaped)\"")
        XCTAssertTrue(escaped.contains(#"\"hi\""#) && escaped.contains(#"\\x"#))
    }

    /// A question card's answers go as a line of their own: the owner's draft and its files stay (unified chat T12).
    func testSendLineLeavesTheDraftAndFilesAlone() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let file = folder.appendingPathComponent("a.png")
        try Data([9]).write(to: file)
        model.attach(files: [file])
        model.draft = "half a thought"

        await model.sendLine("Ship it?\r\n- Yes\n")

        XCTAssertEqual(model.outgoing.first?.text, "Ship it?\n- Yes")
        XCTAssertEqual(model.draft, "half a thought")
        XCTAssertEqual(model.attachments.count, 1)
    }

    func testPathWithLineBreakIsRefused() async throws {
        let model = try makeModel(try await liveSession())
        let file = folder.appendingPathComponent("two\nlines.png")

        model.attach(files: [file])

        XCTAssertTrue(model.attachments.isEmpty)
        let error = try XCTUnwrap(model.attachmentError)
        XCTAssertTrue(error.contains("line break"), error)
    }

    func testAttachFilesUsesPathsAsIs() async throws {
        let model = try makeModel(try await liveSession())
        let file = folder.appendingPathComponent("a b.png")
        try Data([9]).write(to: file)

        model.attach(files: [file])

        XCTAssertEqual(model.attachments.first?.path, file.path)
        XCTAssertEqual(model.attachments.first?.size, 1)
    }

    func testSendComposesTextAndQuotedPaths() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let file = folder.appendingPathComponent("a b.png")
        try Data([9]).write(to: file)
        model.attach(files: [file])
        model.draft = "look"

        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "look\n\"\(file.path)\"")
        XCTAssertEqual(model.outgoing.first?.typedText, "look")
        XCTAssertTrue(model.attachments.isEmpty, "chips clear on send")
    }

    func testAttachmentsOnlySends() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        _ = await model.attach(data: Data([1]), name: "x.png")
        let path = try XCTUnwrap(model.attachments.first?.path)

        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, path.contains(" ") ? "\"\(path)\"" : path)
        XCTAssertEqual(model.outgoing.first?.state, .sent)
    }

    func testNotSentRestoresAttachments() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        _ = await model.attach(data: Data([1]), name: "x.png")
        model.draft = "look"
        await model.send()
        XCTAssertTrue(model.attachments.isEmpty)

        processes[0].onExit?(0)
        statuses[session] = nil
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "look")
        XCTAssertEqual(model.attachments.count, 1)
    }

    // MARK: - Send

    func testSendIdleSubmits() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "  Fix the flaky test\n"

        await model.send()

        XCTAssertEqual(model.draft, "", "the field clears")
        XCTAssertEqual(model.outgoing.map(\.text), ["Fix the flaky test"], "trimmed")
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Fix the flaky test"))
        XCTAssertTrue(typedText.contains("\r"), "submitted with Return")
    }

    func testSendWhileWorkingSubmitsAtOnce() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "Also add the teammate fixture"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.state, .sent)
        XCTAssertTrue(line.sentWhileBusy)
        XCTAssertTrue(typedText.contains("Also add the teammate fixture"))
    }

    func testTwoLinesWhileBusyGoInOrder() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "First"
        await model.send()
        model.draft = "Second"
        await model.send()

        XCTAssertEqual(model.outgoing.map(\.state), [.sent, .queued], "no hook since line 1: line 2 waits")
        // The turn's hook reports; the next state read sends line 2.
        clock.advance(1)
        setState(session, .working)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.map(\.state), [.sent, .sent])
        let first = try XCTUnwrap(typedText.range(of: "First"))
        let second = try XCTUnwrap(typedText.range(of: "Second"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertEqual(typedText.components(separatedBy: "First").count, 2, "once")
        XCTAssertEqual(typedText.components(separatedBy: "Second").count, 2, "once")
        XCTAssertFalse(typedText.contains("FirstSecond"))
    }

    func testQueuedCaptionFollowsTheAgentKind() {
        XCTAssertEqual(WorkchatOutgoing.caption(state: .queued, working: true, holdsUntilIdle: true),
                       "Queued · sends when the agent stops ·")
        XCTAssertEqual(WorkchatOutgoing.caption(state: .queued, working: true, holdsUntilIdle: false),
                       "Queued · sends in a moment ·")
    }

    /// #2065 §5: a working Codex session keeps its hold — the line waits with
    /// "sends when the agent stops" and Cancel drops it.
    func testCodexHoldShowsQueuedCaptionWithCancel() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: { .codex }, now: { clock.now }
        )
        model.draft = "Also add the fixture"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.last)
        XCTAssertEqual(line.state, .queued)
        XCTAssertTrue(model.holdsUntilIdle)
        XCTAssertEqual(WorkchatOutgoing.caption(state: line.state, working: true, holdsUntilIdle: model.holdsUntilIdle),
                       "Queued · sends when the agent stops ·")
        model.cancel(line.id)
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// #2065 §5: background agents run, the main turn is over — the line is
    /// submitted at once and reads as queued for the agent's next step.
    func testBackgroundSendSubmitsAtOnce() async throws {
        let session = try await liveSession()
        setState(session, .background)
        let model = try makeModel(session)
        model.draft = "Also check the docs"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.state, .sent)
        XCTAssertTrue(line.sentWhileBusy)
        XCTAssertTrue(typedText.contains("Also check the docs"))
        XCTAssertEqual(
            WorkchatOutgoing.caption(state: line.state, working: true, holdsUntilIdle: model.holdsUntilIdle,
                                     sentWhileBusy: line.sentWhileBusy),
            "Queued · the agent reads it at its next step"
        )
    }

    func testUnknownKindKeepsTheBusyHold() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: { nil }, now: { clock.now }
        )
        model.draft = "Hello"

        await model.send()

        XCTAssertTrue(model.holdsUntilIdle)
        XCTAssertEqual(model.outgoing.first?.state, .queued)
    }

    func testBusyLineEchoAfterTwoMinutesStillMatches() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "Also add the fixture"
        await model.send()
        let delivered = try XCTUnwrap(model.outgoing.first?.deliveredAt)

        model.reconcile(with: [SessionFeedEntry(
            id: "late", kind: "owner", at: delivered.addingTimeInterval(150), text: "Also add the fixture"
        )])

        XCTAssertTrue(model.outgoing.isEmpty)
    }

    func testIdleLineEchoWindowUnchanged() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Also add the fixture"
        await model.send()
        let delivered = try XCTUnwrap(model.outgoing.first?.deliveredAt)

        model.reconcile(with: [SessionFeedEntry(
            id: "late", kind: "owner", at: delivered.addingTimeInterval(150), text: "Also add the fixture"
        )])

        XCTAssertEqual(model.outgoing.count, 1, "an idle line's echo past the window stays a bubble")
    }

    /// The kind is read at each send, not when the model is made: a pane
    /// restored at launch makes its model before the sessions load.
    func testKindKnownOnlyAfterTheModelIsMadeDropsTheBusyHold() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        var kind: TerminalSession.Kind?
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: { kind }, now: { clock.now }
        )
        XCTAssertTrue(model.holdsUntilIdle, "unknown kind keeps the hold")

        kind = .claude
        model.draft = "Also add the fixture"
        await model.send()

        XCTAssertFalse(model.holdsUntilIdle)
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Also add the fixture"))
    }

    func testShellKindKeepsTheBusyHold() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: { .shell }, now: { clock.now }
        )
        model.draft = "Also add the fixture"

        await model.send()

        XCTAssertTrue(model.holdsUntilIdle)
        XCTAssertEqual(model.outgoing.first?.state, .queued)
    }

    /// A working Codex session holds the line until it stops: its MCP forms
    /// raise no state mid-turn (plan Task G7 spike (c)).
    func testSendWhileWorkingHoldsOnCodex() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: { .codex }, now: { clock.now }
        )
        model.draft = "Also add the fixture"

        await model.send()

        XCTAssertEqual(model.outgoing.first?.state, .queued)
    }

    /// The hold follows the capability row, never the kind: the same kind
    /// holds or not as its injected row says.
    func testHoldsUntilIdleFollowsCapability() throws {
        let control = try makeControl()
        let fullRow: (AgentKind) -> AgentSessionCaps = { _ in AgentSessionCaps.of(AgentKind.claude) }
        let noRow: (AgentKind) -> AgentSessionCaps = { _ in .none }
        let taking = WorkchatModel(
            sessionID: 1, control: control, lineDelivery: delivery, kind: { .codex }, caps: fullRow
        )
        XCTAssertFalse(taking.holdsUntilIdle, "a row that takes lines while working never holds")
        let holding = WorkchatModel(
            sessionID: 1, control: control, lineDelivery: delivery, kind: { .claude }, caps: noRow
        )
        XCTAssertTrue(holding.holdsUntilIdle, "a row without it holds, whatever the kind")
        let shell = WorkchatModel(sessionID: 1, control: control, lineDelivery: delivery) { .shell }
        XCTAssertTrue(shell.holdsUntilIdle, "a shell has no agent row")
    }

    func testSendWhileApprovalPendingQueues() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Also add the teammate fixture"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.state, .queued)
        XCTAssertEqual(typedText, "", "nothing typed over a permission prompt")
        XCTAssertEqual(delivery.heldKeys(sessionID: session), [.workchat(line.id)])

        // The agent stops: the next state read sends it.
        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Also add the teammate fixture"))
    }

    /// Review Focus 1: the owner's half-typed text sits in the terminal
    /// prompt; the Workchat line is held, never appended to that draft.
    func testLineHeldWhilePromptHoldsText() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "Run the linter"

        await model.send()

        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertFalse(typedText.contains("Run the linter"), "never typed after the owner's draft")
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .queued, "still held while the draft is there")
        XCTAssertFalse(typedText.contains("Run the linter"))
    }

    /// Spec §6.3: a held line says why it waits — the check that held it.
    func testHeldLineCarriesItsHoldReason() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Approve first"
        await model.send()
        XCTAssertEqual(model.outgoing.first?.holdReason, .needsApproval)

        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertEqual(model.outgoing.first?.holdReason, .promptHasText)

        processes[0].onOwnerInput?(Array("\r".utf8))
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertNil(model.outgoing.first?.holdReason, "a line that went waits for nothing")
    }

    /// Spec §6.3: the prompt's line shows under a line held for its text,
    /// as the screen shows it; nothing for another hold or no line.
    func testHoldPreviewInCaption() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("look at the window test again".utf8))
        var preview: String? = "> look at the window test again "
        let model = try makeModel(session) { _ in preview }
        model.draft = "Run the gate."
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)

        XCTAssertEqual(model.outgoing.first?.holdReason, .promptHasText)
        XCTAssertEqual(model.holdPreview(for: id), "> look at the window test again")
        preview = nil
        XCTAssertNil(model.holdPreview(for: id), "no line on screen: the caption alone")
        preview = "   "
        XCTAssertNil(model.holdPreview(for: id))
        XCTAssertEqual(TerminalCenter.promptPreview(row: "│ > look at it        │"), "> look at it")
        XCTAssertNil(TerminalCenter.promptPreview(row: "╰──────╯"))

        setState(session, .needsApproval)
        await delivery.deliverHeld()
        preview = "> look"
        XCTAssertNil(model.holdPreview(for: id), "held for the permission prompt, not the text")
    }

    /// Spec §6.3: Send together types the held line beside the prompt's
    /// text without a Return of the app's; the owner's one Return sends both.
    func testSendTogether() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].host.tracksDrafts = true
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "Run the linter"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        XCTAssertEqual(model.outgoing.first?.holdReason, .promptHasText)

        await model.sendTogether(id)

        XCTAssertEqual(model.outgoing.first?.state, .typed)
        XCTAssertTrue(typedText.contains("Run the linter"), "pasted beside the owner's text")
        XCTAssertFalse(processes[0].inputs.contains([0x0D]), "no Return of the app's over the owner's text")
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
        XCTAssertTrue(center.sharedPrompts.contains(session), "the pane says one Return sends both")
        processes[0].onOwnerInput?([0x0D])
        XCTAssertFalse(center.promptHoldsText(session), "the owner's one Return sent them")
    }

    /// Fix round 1 (codex P1): Send together keeps the held line's run. A
    /// relaunch between the hold and the click starts another run: the line
    /// is not sent, its text back in the field, nothing typed into the new run.
    func testSendTogetherAfterARelaunchIsNotSent() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "Run the linter"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        XCTAssertEqual(model.outgoing.first?.holdReason, .promptHasText)

        processes[0].onExit?(0)
        center.start(try XCTUnwrap(lastRow), fresh: false)
        XCTAssertTrue(center.liveIDs.contains(session))
        await model.sendTogether(id)

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "Run the linter", "back in the field")
        XCTAssertFalse(typedText.contains("Run the linter"), "never typed into the new run")
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
    }

    /// Fix round 1 (codex P2): the transcript records the prompt's text and the
    /// line sent together as one owner entry; it is the line's echo.
    func testSendTogetherEchoIsTheCombinedEntry() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].host.tracksDrafts = true
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "Run the linter"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        await model.sendTogether(id)
        XCTAssertEqual(model.outgoing.first?.state, .typed)

        model.reconcile(with: [owner("fix theRun the linter", after: 3)])

        XCTAssertTrue(model.outgoing.isEmpty, "the combined entry is its echo")
    }

    /// Fix round 2 (codex N1): Send together on line B while a sweep of the held
    /// lines is delivering line A. The sweep's copy of B is stale; B is tried as
    /// the live queue holds it — under Send together's gate — and goes beside the
    /// prompt's text instead of being held again.
    func testSendTogetherDuringASweepIsNotUndoneByIt() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].host.tracksDrafts = true
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "First"
        await model.send()
        model.draft = "Second"
        await model.send()
        let second = try XCTUnwrap(model.outgoing.last?.id)
        XCTAssertEqual(model.outgoing.map(\.holdReason), [.promptHasText, .promptHasText])

        let gate = Gate()
        delivery.refreshStates = { await gate.wait(); return true }
        let lines = try XCTUnwrap(delivery)
        let sweep = Task {
            await lines.deliverHeld()
            gate.ended()
        }
        guard await gate.parked() else {
            XCTFail("the sweep never reached its state read")
            return
        }
        await model.sendTogether(second)
        XCTAssertEqual(model.outgoing.last?.state, .queued, "behind the first, which is on its way")
        gate.release()
        await sweep.value
        await delivery.settled()

        XCTAssertEqual(model.outgoing.first?.state, .queued, "the first is still held for the text")
        XCTAssertEqual(model.outgoing.last?.state, .typed, "the second went beside the text")
        XCTAssertTrue(typedText.contains("Second"))
        XCTAssertFalse(typedText.contains("First"))
    }

    /// Fix round 1 (codex P2): the hold reason is the try's own. A failed state
    /// read holds the line for no known reason — the generic caption, no Send
    /// together — even while the prompt holds text.
    func testAFailedStateReadGivesNoHoldReason() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))
        delivery.refreshStates = { false }
        let model = try makeModel(session)
        model.draft = "Run the linter"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)

        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertNil(model.outgoing.first?.holdReason)
        await model.sendTogether(id)
        XCTAssertEqual(model.outgoing.first?.state, .queued, "no Send together for an unknown hold")
        XCTAssertFalse(typedText.contains("Run the linter"))
    }

    /// Fix round 1 (claude minor 6): an agent that holds lines until idle and
    /// works holds the line as busy.
    func testAWorkingHoldUntilIdleAgentGivesAgentBusy() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: { .codex }, now: { clock.now }
        )
        model.draft = "After this turn"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.holdReason, .agentBusy)
        XCTAssertEqual(WorkchatOutgoing.caption(state: line.state, working: true, holdsUntilIdle: model.holdsUntilIdle,
                                                holdReason: line.holdReason),
                       "Queued · sends when the agent stops")
    }

    /// Send together is only for a line held for the prompt's text: a line
    /// held for a permission prompt stays held.
    func testSendTogetherIgnoresOtherHolds() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Wait for it"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)

        await model.sendTogether(id)

        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertEqual(delivery.heldKeys(sessionID: session), [.workchat(id)])
        XCTAssertEqual(typedText, "")
    }

    /// Failure and races: a line held for the prompt's text whose session
    /// ends is not sent, its text back in the field.
    func testHeldThenSessionGone() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "Run the linter"
        await model.send()
        XCTAssertEqual(model.outgoing.first?.holdReason, .promptHasText)

        processes[0].onExit?(0)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertNil(model.outgoing.first?.holdReason)
        XCTAssertEqual(model.draft, "Run the linter", "back in the field")
    }

    func testCancelDropsHeldLine() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Never mind"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)

        model.cancel(id)

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertEqual(typedText, "", "a cancelled line is never typed")
    }

    /// Cancel on a line that is not queued — on its first try, or sent —
    /// changes nothing (final review m7).
    func testCancelOnALineNotQueuedIsANoOp() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        let gate = Gate()
        delivery.refreshStates = { await gate.wait(); return true }
        model.draft = "Hold on"
        let sending = Task { await model.send() }
        await gate.untilReached()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        XCTAssertEqual(model.outgoing.first?.state, .sending)

        model.cancel(id)
        XCTAssertEqual(model.outgoing.map(\.id), [id], "a line on its first try stays")
        gate.release()
        await sending.value
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertEqual(delivery.heldKeys(sessionID: session), [.workchat(id)], "nothing was dropped from the queue")

        delivery.refreshStates = { true }
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        model.cancel(id)
        XCTAssertEqual(model.outgoing.map(\.state), [.sent], "a sent line stays")
    }

    /// A queued line whose retry is under way is out of the queue:
    /// `dropHeld` finds nothing and the line stays (final review m7).
    func testCancelKeepsALineWhoseRetryIsUnderWay() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Run it"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        XCTAssertEqual(model.outgoing.first?.state, .queued)

        let gate = Gate()
        delivery.refreshStates = { await gate.wait(); return true }
        setState(session, .stopped)
        let retry = Task { await delivery.deliverHeld() }
        await gate.untilReached()
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty, "taken out for its retry")

        model.cancel(id)
        XCTAssertEqual(model.outgoing.map(\.id), [id], "nothing was dropped: the line stays")
        gate.release()
        await retry.value
        XCTAssertEqual(model.outgoing.first?.state, .sent)
    }

    /// Review Focus 2: the session ends while a line waits. The bubble says
    /// it was not sent and the text comes back to the field.
    func testQueuedLineAfterSessionEndsReturnsToField() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Add the fixture"
        await model.send()
        XCTAssertEqual(model.draft, "")

        processes[0].onExit?(0)
        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "Add the fixture", "back in the field")
        XCTAssertEqual(typedText, "")
    }

    /// The field holds a newer draft: it is kept, the bubble still says the
    /// line was not sent.
    func testNotSentLineKeepsANewerDraft() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "First"
        await model.send()
        model.draft = "Second, still typing"

        processes[0].onExit?(0)
        statuses[session] = nil
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "Second, still typing")
    }

    func testEmptyLineNotSent() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "  \n\t "

        await model.send()

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(typedText, "")
    }

    // MARK: - Reconcile

    func testReconcileRemovesEchoedLine() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Ship it"
        await model.send()

        model.reconcile(with: [owner("Ship it", after: -10), owner("Something else", after: 1)])
        XCTAssertEqual(model.outgoing.count, 1, "an older identical line is not its echo")

        model.reconcile(with: [owner("Ship it", after: -10), owner("Ship it", after: 1)])
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// Two identical lines: one echo stands for one of them only.
    func testReconcileMatchesOneEchoPerLine() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Again"
        await model.send()
        clock.advance(31)
        setState(session, .stopped)
        model.draft = "Again"
        await model.send()
        XCTAssertEqual(model.outgoing.map(\.state), [.sent, .sent])

        let echo = owner("Again", after: 1)
        model.reconcile(with: [echo])
        XCTAssertEqual(model.outgoing.count, 1)
        model.reconcile(with: [echo, owner("Again", after: 2)])
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// A Workchat line keeps its line breaks (owner ask #421, PROJ-12
    /// amended): the typed paste, the bubble and the echo agree.
    func testMultilineDraftKeepsLineBreaks() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Fix the test\r\nand run it \n"

        await model.send()

        XCTAssertEqual(model.outgoing.map(\.text), ["Fix the test\nand run it"])
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Fix the test\nand run it"), "typed with its line break: \(typedText)")
        model.reconcile(with: [owner("Fix the test\nand run it", after: 1)])
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    func testWhitespaceOnlyDraftNotSent() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = " \n\t\n "
        await model.send()
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(typedText, "")
    }

    /// The pane was off screen past the window: an echo dated in time still
    /// takes the line when the feed is read at last.
    func testLateReconcileStillMatchesTimelyEcho() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Ship it"
        await model.send()
        let echo = owner("Ship it", after: 2)

        clock.advance(120)
        model.reconcile(with: [echo])

        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// A feed read holding the echo landed while the line was still on its
    /// way: settling matches it against that read.
    func testEchoSeenWhileSendingReconcilesOnSettle() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Later"
        await model.send()
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        model.reconcile(with: [owner("Later", after: 1)])
        XCTAssertEqual(model.outgoing.count, 1, "a queued line has no echo yet")

        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertTrue(model.outgoing.isEmpty, "the echo already read takes it")
    }

    /// The same text typed in the terminal while the line sat queued is
    /// dated before its delivery: it is not the line's echo (final review m1).
    func testOwnerEntryWhileQueuedIsNotTheEcho() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Ship it"
        await model.send()
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        let typedMeanwhile = owner("Ship it", after: 5)

        clock.advance(20)
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .sent)

        model.reconcile(with: [typedMeanwhile])
        XCTAssertEqual(model.outgoing.count, 1, "the bubble stays")

        model.reconcile(with: [typedMeanwhile, owner("Ship it", after: -1)])
        XCTAssertTrue(model.outgoing.isEmpty, "an echo stamped just before deliveredAt still takes it")
    }

    /// No echo within `echoWindow` (a `/clear`, say): the line stays as a
    /// plain local bubble, and a late identical entry does not take it.
    func testReconcileKeepsLineWithoutEchoPastWindow() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "/clear"
        await model.send()

        clock.advance(WorkchatOutgoing.echoWindow + 1)
        model.reconcile(with: [owner("/clear", after: 0)])

        XCTAssertEqual(model.outgoing.map(\.text), ["/clear"])
    }

    // MARK: - Stop

    func testStopRefusedWithPendingRequest() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let workbench = workbenchID
        let created = SessionAgentStatus.formatStamp(clock.now)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests
                        (terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
                    VALUES (?, ?, 'Bash', 'make test', 0, 'pending', ?)
                    """,
                arguments: [session, workbench, created]
            )
        }
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .awaitingApproval)
        XCTAssertTrue(processes.flatMap(\.inputs).isEmpty, "no Esc over a prompt")
    }

    func testStopSendsEscWhileWorking() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(processes.flatMap(\.inputs), [[0x1B]])
    }

    /// Refusals say why (final review m6); the result is still returned.
    func testStopRefusedWithPendingRequestSaysWhy() async throws {
        let session = try await liveSession()
        setState(session, .working)
        try await insertRequest(session, summary: "make test")
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .awaitingApproval)
        XCTAssertEqual(model.stopError, "A permission prompt is open — answer it on the card or in the terminal")
    }

    func testStopOnASessionNotRunningSaysWhy() async throws {
        let session = try await liveSession()
        setState(session, .working)
        processes[0].onExit?(0)
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .notRunning)
        XCTAssertEqual(model.stopError, "The session is not running")
    }

    /// A failed check sets `stopError`; the next Stop that goes clears it.
    func testStopErrorClearsOnTheNextSuccess() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let control = ScriptedControl(base: try makeControl())
        control.interrupt = { throw Failure() }
        let model = try makeModel(session, control: control)

        let failed = await model.stop()
        XCTAssertEqual(failed, .notWorking)
        XCTAssertEqual(model.stopError, "Could not check for a permission prompt: disk I/O error")

        control.interrupt = nil
        let sent = await model.stop()
        XCTAssertEqual(sent, .sent)
        XCTAssertNil(model.stopError)
    }

    // MARK: - Permission

    @discardableResult
    private func insertRequest(_ sessionID: Int64, summary: String = "gh pr merge 340 --merge", clipped: Bool = false) async throws -> Int64 {
        let workbench = workbenchID
        let created = SessionAgentStatus.formatStamp(clock.now)
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests
                        (terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
                    VALUES (?, ?, 'Bash', ?, ?, 'pending', ?)
                    """,
                arguments: [sessionID, workbench, summary, clipped, created]
            )
            return db.lastInsertedRowID
        }
    }

    private func storedRequest(_ id: Int64) async throws -> (status: String, decidedBy: String?) {
        try await pool.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT status, decided_by FROM permission_requests WHERE id = ?", arguments: [id]))
            return (row["status"], row["decided_by"])
        }
    }

    func testPermissionCardShownForPendingRow() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        XCTAssertNil(model.permission)

        await model.refreshPermission()

        let card = try XCTUnwrap(model.permission)
        XCTAssertEqual(card.id, id)
        XCTAssertEqual(card.toolName, "Bash")
        XCTAssertEqual(card.summary, "gh pr merge 340 --merge")
        XCTAssertNil(card.allowBlock, "Allow is offered")
    }

    func testAllowAppliesAndClears() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()

        await model.answer(allow: true)

        XCTAssertNil(model.permission)
        XCTAssertNil(model.permissionError)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "allowed")
        XCTAssertEqual(stored.decidedBy, "Mac")
        XCTAssertTrue(processes.flatMap(\.inputs).isEmpty, "only the hook decides: nothing typed")
    }

    /// Review Focus 5: the phone (or the terminal) answered first. The
    /// Workchat's answer changes nothing and the card leaves.
    func testAnsweredElsewhereRemovesCard() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()
        XCTAssertNotNil(model.permission)
        try await pool.write { db in
            try db.execute(sql: "UPDATE permission_requests SET status = 'denied', decided_by = 'iPhone' WHERE id = ?", arguments: [id])
        }

        await model.answer(allow: true)

        XCTAssertNil(model.permission, "the card leaves")
        XCTAssertNil(model.permissionError)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "denied", "the first answer stands")
        XCTAssertEqual(stored.decidedBy, "iPhone")

        // A state change alone also drops a card answered elsewhere.
        try await insertRequest(session, summary: "make test")
        await model.refreshPermission()
        let next = try XCTUnwrap(model.permission)
        try await pool.write { db in
            try db.execute(sql: "UPDATE permission_requests SET status = 'allowed' WHERE id = ?", arguments: [next.id])
        }
        await model.refreshPermission()
        XCTAssertNil(model.permission)
    }

    func testAllowBlockedKeepsDenyOnly() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session, summary: "rm -rf build && …", clipped: true)
        let model = try makeModel(session)
        await model.refreshPermission()
        XCTAssertEqual(model.permission?.allowBlock, .clipped, "Deny and Show in Terminal only")

        await model.answer(allow: true)

        XCTAssertEqual(model.permission?.id, id, "the card stays")
        XCTAssertEqual(model.permission?.allowBlock, .clipped)
        let pending = try await storedRequest(id)
        XCTAssertEqual(pending.status, "pending", "an allow is refused")

        await model.answer(allow: false)

        XCTAssertNil(model.permission)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "denied", "a deny always may")
    }

    /// The session ended under the card: it leaves, the row is not written.
    func testAnswerAfterSessionEndsClears() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()
        processes[0].onExit?(0)

        await model.answer(allow: true)

        XCTAssertNil(model.permission)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "pending")
    }

    /// Prompt B arrives right after A was answered here, and its hook sets
    /// Needs approval again within one state poll: the kind never changes,
    /// but the hook stamp does, and the pane's read key with it.
    func testNextPromptShowsAfterHookStampChanges() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()
        let before = WorkchatModel.PermissionReadKey(statuses[session])

        await model.answer(allow: true)
        XCTAssertNil(model.permission, "B's row is not written yet")

        let second = try await insertRequest(session, summary: "make test")
        clock.advance(1)
        setState(session, .needsApproval)
        let after = WorkchatModel.PermissionReadKey(statuses[session])
        XCTAssertEqual(before.kind, after.kind)
        XCTAssertNotEqual(before, after, "a new hook stamp re-runs the read")

        await model.refreshPermission()
        XCTAssertEqual(model.permission?.id, second)
    }

    /// A failed read before the first card: no card, the error kept for
    /// the pane's caption (final review M4).
    func testFailedPermissionReadWithoutACardKeepsTheError() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let control = ScriptedControl(base: try makeControl())
        control.pending = { _ in throw Failure() }
        let model = try makeModel(session, control: control)

        await model.refreshPermission()

        XCTAssertNil(model.permission)
        XCTAssertEqual(model.permissionError, "Could not read the permission prompt: disk I/O error")
    }

    /// An answer that fails keeps the card and says why (final review m7).
    func testFailedAnswerKeepsTheCard() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let control = ScriptedControl(base: try makeControl())
        let model = try makeModel(session, control: control)
        await model.refreshPermission()
        control.answer = { throw Failure() }

        await model.answer(allow: true)

        XCTAssertEqual(model.permission?.id, id, "the card stays")
        XCTAssertEqual(model.permissionError, "Could not answer the prompt: disk I/O error")
        XCTAssertFalse(model.answering)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "pending")
    }

    /// A second Allow or Deny while one is on its way is ignored.
    func testSecondAnswerWhileAnsweringIsIgnored() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let control = ScriptedControl(base: try makeControl())
        let model = try makeModel(session, control: control)
        await model.refreshPermission()
        let gate = Gate()
        let base = control.base
        control.answer = {
            await gate.wait()
            return try await base.answerPermission(requestID: id, sessionID: session, allow: true, decidedBy: WorkchatModel.decidedBy)
        }
        let first = Task { await model.answer(allow: true) }
        await gate.untilReached()
        XCTAssertTrue(model.answering)

        await model.answer(allow: false)

        XCTAssertEqual(control.answers, 1, "the second answer never reached the control")
        gate.release()
        await first.value
        XCTAssertFalse(model.answering)
        XCTAssertNil(model.permission)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "allowed", "the first answer, the only one")
    }

    /// A read that started before an answer and finishes after it is
    /// stale: the answered card does not come back (final review m7).
    func testReadFinishingAfterAnAnswerDoesNotBringTheCardBack() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let control = ScriptedControl(base: try makeControl())
        let model = try makeModel(session, control: control)
        await model.refreshPermission()
        let stale = try XCTUnwrap(model.permission)
        XCTAssertEqual(stale.id, id)

        let gate = Gate()
        var reads = 0
        let base = control.base
        control.pending = { sessionID in
            reads += 1
            // The first read waits past the answer; the answer's own read is real.
            guard reads == 1 else { return try await base.pendingPermission(sessionID) }
            await gate.wait()
            return stale
        }
        let read = Task { await model.refreshPermission() }
        await gate.untilReached()

        await model.answer(allow: true)
        XCTAssertNil(model.permission)
        gate.release()
        await read.value

        XCTAssertNil(model.permission, "the old read is dropped")
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "allowed")
    }

    /// Codex writes no permission rows: no card.
    func testNoPermissionCardForCodexSession() async throws {
        let session = try await liveSession(kind: .codex)
        setState(session, .working)
        let model = try makeModel(session)

        await model.refreshPermission()

        XCTAssertNil(model.permission)
    }

    // MARK: - Paste tokens (#2065 §6)

    private func imagePath(_ model: WorkchatModel, _ number: Int) throws -> String {
        guard case let .image(path)? = model.pastes[number] else {
            XCTFail("no image payload #\(number)")
            throw CancellationError()
        }
        return path
    }

    func testPasteTokensNumberUpPerDraft() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let long = (1...42).map { "line \($0)" }.joined(separator: "\n")

        let image = await model.paste(.image(Data([1, 2]), name: "Pasted image.png"))
        let text = await model.paste(.text(long))

        XCTAssertEqual(image, "[Image #1]")
        XCTAssertEqual(text, "[Pasted text #2 +42 lines]")
        XCTAssertTrue(model.attachments.isEmpty, "a pasted image is a token, not a chip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try imagePath(model, 1)), "saved at paste time")
        XCTAssertEqual(model.pastes[2], .text(long))

        model.draft = "see \(image ?? "") and \(text ?? "")"
        await model.send()

        XCTAssertTrue(model.pastes.isEmpty, "the send takes the payloads")
        let next = await model.paste(.text("x"))
        XCTAssertEqual(next, "[Pasted text #1 +1 lines]", "numbering starts again with a new draft")
    }

    func testPasteNumberSkipsHandTypedNumbers() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "like [Image #1] here "

        let pasted = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        let label = try XCTUnwrap(pasted)
        XCTAssertEqual(label, "[Image #2]")
        model.draft += label
        let path = try imagePath(model, 2)
        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "like [Image #1] here \(WorkchatOutgoing.quoted(path))",
                       "the hand-typed bracket text stays as typed")
    }

    func testPasteImageSaveFailureInsertsNoToken() async throws {
        let session = try await liveSession()
        let blocker = folder.appendingPathComponent("not-a-folder")
        try Data([0]).write(to: blocker)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery,
            attachmentStore: WorkchatAttachmentStore(root: blocker), kind: { .claude }, now: { clock.now }
        )

        let label = await model.paste(.image(Data([1]), name: "Pasted image.png"))

        XCTAssertNil(label)
        XCTAssertTrue(model.pastes.isEmpty)
        XCTAssertTrue(model.attachments.isEmpty)
        let error = try XCTUnwrap(model.attachmentError)
        XCTAssertTrue(error.hasPrefix("Could not save the pasted file: "), error)
    }

    func testSendExpandsTokens() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        _ = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        _ = await model.paste(.text("x\r\ny"))
        let path = try imagePath(model, 1)
        let draft = "fix [Image #1] see [Pasted text #2 +2 lines]"
        model.draft = draft

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.text, "fix \(WorkchatOutgoing.quoted(path)) see x\ny")
        XCTAssertEqual(line.typedText, draft, "the tokenized draft")
        XCTAssertEqual(line.attachmentPaths, [path])
        XCTAssertEqual(line.state, .sent)
        XCTAssertTrue(typedText.contains("see x"), "the expanded text goes to the terminal")
    }

    func testDroppedImageStaysChip() async throws {
        let model = try makeModel(try await liveSession())
        let file = folder.appendingPathComponent("shot.png")
        try Data([9]).write(to: file)

        model.attach(files: [file])

        XCTAssertEqual(model.attachments.map(\.path), [file.path], "a dropped or picked image is a chip")
        XCTAssertTrue(model.pastes.isEmpty, "no token")
    }

    func testDeletedTokenDropsItsPayload() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        _ = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        _ = await model.paste(.text("secret\nstuff"))
        model.draft = "only [Image #1] [Pasted text #2 +2 lines]"
        model.draft = "only [Image #1]"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertFalse(line.text.contains("secret"), line.text)
        model.cancel(line.id)
        XCTAssertEqual(model.draft, "only [Image #1]")
        XCTAssertEqual(Set(model.pastes.keys), [1], "the deleted token's payload is gone")
    }

    func testImageGoneRefusesSendKeepsDraft() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        _ = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        try FileManager.default.removeItem(atPath: try imagePath(model, 1))
        model.draft = "fix [Image #1]"

        await model.send()

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(typedText, "")
        XCTAssertEqual(model.attachmentError, "Pasted image #1 is gone — paste it again")
        XCTAssertEqual(WorkchatModel.imageGone(1), "Pasted image #1 is gone — paste it again")
        XCTAssertEqual(model.draft, "fix [Image #1]")
        XCTAssertNotNil(model.pastes[1])
    }

    func testNotSentRestoresTokenizedDraftAndPayloads() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        _ = await model.paste(.text("x\ny"))
        model.draft = "a [Pasted text #1 +2 lines]"
        await model.send()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.pastes.isEmpty)

        processes[0].onExit?(0)
        statuses[session] = nil
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "a [Pasted text #1 +2 lines]")
        XCTAssertEqual(model.pastes, [1: .text("x\ny")])
    }

    func testCancelRestoresTokenizedDraftAndPayloads() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        _ = await model.paste(.text("x\ny"))
        model.draft = "a [Pasted text #1 +2 lines]"
        await model.send()
        let first = try XCTUnwrap(model.outgoing.first?.id)

        model.cancel(first)

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(model.draft, "a [Pasted text #1 +2 lines]")
        XCTAssertEqual(model.pastes, [1: .text("x\ny")])

        // A newer draft is kept.
        await model.send()
        let second = try XCTUnwrap(model.outgoing.first?.id)
        model.draft = "newer"
        model.cancel(second)
        XCTAssertEqual(model.draft, "newer")
        XCTAssertTrue(model.pastes.isEmpty)
    }

    /// Review Focus 4: a bracket text the owner typed has no payload: Backspace takes one character and it goes as
    /// typed.
    func testHandTypedTokenIsPlainText() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "[Image #1]"

        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 10, in: model.draft, live: Set(model.pastes.keys)))
        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "[Image #1]")
        XCTAssertNil(model.attachmentError)
    }

    // MARK: - Paste tokens, fix round 1

    /// Backspace takes the token and its payload; the same text typed again by hand is plain text (spec §6).
    func testDeletedTokenPayloadDoesNotComeBack() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let labelPasted = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        let label = try XCTUnwrap(labelPasted)
        model.draft = "fix \(label)"
        XCTAssertNotNil(model.pastes[1])

        model.draft = "fix "
        XCTAssertTrue(model.pastes.isEmpty, "the payload leaves with its token")
        model.draft = "fix [Image #1]"
        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "fix [Image #1]", "a retyped token is plain text")
        XCTAssertEqual(model.outgoing.first?.attachmentPaths, [])
        model.draft = "again "
        let next = await model.paste(.text("x"))
        XCTAssertEqual(next, "[Pasted text #1 +1 lines]")
    }

    /// A pruned number is not given out again within the draft.
    func testPrunedNumberIsNotReused() async throws {
        let model = try makeModel(try await liveSession())
        let firstPasted = await model.paste(.text("a"))
        let first = try XCTUnwrap(firstPasted)
        model.draft = first
        model.draft = ""
        let second = await model.paste(.text("b"))
        XCTAssertEqual(second, "[Pasted text #2 +1 lines]")
    }

    /// A hand-typed token of the other kind does not keep a payload of the same number live.
    func testLiveNumbersAreKindAware() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let labelPasted = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        let label = try XCTUnwrap(labelPasted)
        model.draft = label

        model.draft = "[Pasted text #1 +3 lines]"
        XCTAssertTrue(model.pastes.isEmpty, "image #1 has no token of its kind left")
        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "[Pasted text #1 +3 lines]")
    }

    /// A label typed by hand beside the live token of the same number is plain text: the draft cannot tell the
    /// copies apart, so neither expands and the payload goes (final fix, spec §6 "hand-typed stays literal").
    func testHandTypedDuplicateOfALiveTokenStaysLiteral() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let pasted = await model.paste(.image(Data([1]), name: "Pasted image.png"))
        let label = try XCTUnwrap(pasted)
        model.draft = "fix \(label)"
        XCTAssertNotNil(model.pastes[1])

        model.draft = "fix \(label) like [Image #1]"
        XCTAssertTrue(model.pastes.isEmpty, "a duplicated label holds no payload")
        XCTAssertEqual(model.attachmentError, "Pasted image #1 appears twice — paste it again", "the drop is not silent")
        XCTAssertEqual(WorkchatModel.pasteDuplicated(1, kind: .image), "Pasted image #1 appears twice — paste it again")
        XCTAssertEqual(WorkchatModel.pasteDuplicated(2, kind: .text), "Pasted text #2 appears twice — paste it again")
        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "fix [Image #1] like [Image #1]")
        XCTAssertEqual(model.outgoing.first?.attachmentPaths, [])
    }

    /// Deleting the pasted token while a typed copy stays leaves the copy literal, not holding the payload.
    func testDeletingTheRealTokenDropsThePayloadEvenWithATypedCopy() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let pasted = await model.paste(.text("secret\nstuff"))
        let label = try XCTUnwrap(pasted)
        model.draft = "\(label) copy: [Pasted text #1 +2 lines]"

        XCTAssertEqual(model.attachmentError, "Pasted text #1 appears twice — paste it again")
        model.draft = " copy: [Pasted text #1 +2 lines]"
        XCTAssertTrue(model.pastes.isEmpty)
        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.text, "copy: [Pasted text #1 +2 lines]")
        XCTAssertFalse(line.text.contains("secret"))
    }

    /// A Return in the hop between the paste and its token landing does not send: the draft and the payload stay
    /// for the token (final fix).
    func testSendWaitsForAPendingPasteToken() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "see "
        let pasted = await model.paste(.text("x\ny"))
        let label = try XCTUnwrap(pasted)

        await model.send()
        XCTAssertTrue(model.outgoing.isEmpty, "the token has not landed yet")
        XCTAssertEqual(model.draft, "see ")
        XCTAssertEqual(model.pastes, [1: .text("x\ny")])

        model.draft += label
        await model.send()
        XCTAssertEqual(model.outgoing.first?.text, "see x\ny")
    }

    /// A token the field could not insert (edit refused, field gone) does not hold Send: the paste is let go
    /// (final fix follow-up).
    func testSendWorksAgainAfterARefusedInsert() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "hi"
        let pasted = await model.paste(.text("x\ny"))
        let label = try XCTUnwrap(pasted)
        await model.send()
        XCTAssertTrue(model.outgoing.isEmpty, "held while the token may still land")

        model.pasteNotInserted(label)
        XCTAssertTrue(model.pastes.isEmpty, "the payload goes with the token")
        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, "hi")
    }

    func testPasteNumberIgnoresHugeHandTypedNumber() async throws {
        let model = try makeModel(try await liveSession())
        model.draft = "[Image #\(Int.max)] [Pasted text #2000000 +1 lines] [Image #4]"

        let label = await model.paste(.text("x"))

        XCTAssertEqual(label, "[Pasted text #5 +1 lines]")
    }

    /// The draft is trimmed around its tokens, not inside a pasted text.
    func testPastedTextKeepsItsWhitespace() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let code = "    indented()\n        deeper()\n\n"
        let labelPasted = await model.paste(.text(code))
        let label = try XCTUnwrap(labelPasted)
        model.draft = "  \(label)  "

        await model.send()

        XCTAssertEqual(model.outgoing.first?.text, code)
    }

    /// A draft holding only a whitespace paste is refused like an empty one.
    func testWhitespaceOnlyPasteNotSent() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        let labelPasted = await model.paste(.text(" \n\t\n"))
        let label = try XCTUnwrap(labelPasted)
        model.draft = label

        await model.send()

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(typedText, "")
        XCTAssertEqual(model.draft, label)
    }
}
