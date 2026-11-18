import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// The journal's OK, Correct… and Open session (spec §10, D26): the
/// feedback row is written first, then the correction goes to the live
/// session as a typed line, or a new session starts with it; a failed
/// delivery keeps the correction and offers Retry.
@MainActor
final class WatchmanCorrectTests: XCTestCase {
    /// Every call the journal's actions received, in order.
    private final class Recorder: @unchecked Sendable {
        var calls: [String] = []
        var writes: [WatchmanFeedbackWrite] = []
        var lines: [(line: String, itemID: Int64, sessionID: Int64)] = []
        var starts: [(item: Int64, line: String)] = []
        var routes: [WorkbenchRoute] = []
        var heldCallback: ((SessionLineDelivery.HeldEvent) -> Void)?
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private func date(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }

    private func item(
        _ id: Int64 = 1826,
        session: Int64 = 3,
        target: Int64 = 1801,
        outcome: String = "answered",
        feedback: String = "",
        feedbackText: String = "",
        sentAt: Date? = nil
    ) -> WatchmanItem {
        WatchmanItem(id: id, workbenchID: 1, workbenchName: "acme-api", sessionID: session, targetID: target,
                     outcome: outcome, question: "Store the window per workbench or global?", choice: "Per workbench",
                     rationale: "You split settings per workbench.", confidence: "low", category: "design",
                     createdAt: date("2026-11-17T02:14:00Z"), decidedAt: date("2026-11-17T02:15:00Z"),
                     feedback: feedback, feedbackText: feedbackText, correctionSentAt: sentAt)
    }

    private func model(
        _ items: [WatchmanItem],
        recorder: Recorder,
        live: Bool = true,
        writes: Bool = true,
        delivery: SessionLineDelivery.Delivery = .submitted,
        start: Result<Int64, Error> = .success(42)
    ) -> WatchmanJournalViewModel {
        let night = WatchmanNight(date: date("2026-11-16T12:00:00Z"), decided: items)
        let actions = WatchmanJournalViewModel.Actions(
            write: { change in
                recorder.calls.append("write")
                recorder.writes.append(change)
                return writes
            },
            isLive: { _ in live },
            deliver: { line, itemID, sessionID, onHeld in
                recorder.calls.append("deliver")
                recorder.lines.append((line, itemID, sessionID))
                recorder.heldCallback = onHeld
                return live ? delivery : .noSession
            },
            startSession: { item, line in
                recorder.calls.append("start")
                recorder.starts.append((item.id, line))
                return try start.get()
            },
            open: { recorder.routes.append($0) }
        )
        let now = date("2026-11-17T09:00:00Z")
        let vm = WatchmanJournalViewModel(read: { .init(nights: [night], deciding: []) }, now: { now },
                                          calendar: calendar, actions: actions)
        vm.apply(.success(.init(nights: [night], deciding: [])))
        return vm
    }

    private func correct(_ vm: WatchmanJournalViewModel, _ text: String = "Global, one window for all.") async {
        vm.beginCorrect(1826)
        vm.correcting?.text = text
        await vm.sendCorrection()
    }

    func testCardActionsCopy() {
        let vm = model([item()], recorder: Recorder())
        XCTAssertEqual([vm.okTitle, vm.correctTitle, vm.openSessionTitle, vm.markDoneTitle],
                       ["OK", "Correct…", "Open session", "Mark done"])
        XCTAssertEqual([vm.sheetTitle, vm.sheetQuestion, vm.cancelTitle, vm.sendTitle],
                       ["Correct this decision", "What would you have decided?", "Cancel", "Send Correction"])
        let card = vm.page?.decided.first
        XCTAssertEqual(card?.canJudge, true)
        XCTAssertEqual(card?.canOpen, true)
        XCTAssertNil(card?.feedbackLine)
    }

    /// OK writes once through the feedback queries; a judged card offers
    /// neither OK nor Correct… again and says what the owner said.
    func testOKWritesOnce() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder)
        await vm.ok(1826)
        XCTAssertEqual(recorder.writes, [.ok(1826)])
        let judged = model([item(feedback: "ok")], recorder: Recorder())
        XCTAssertEqual(judged.page?.decided.first?.canJudge, false)
        XCTAssertEqual(judged.page?.decided.first?.feedbackLine, "You marked this OK — Watchman learns from it")
        var corrected = item(feedback: "corrected")
        corrected.feedbackText = "Global.\nOne window."
        let shown = model([corrected], recorder: Recorder())
        XCTAssertEqual(shown.page?.decided.first?.feedbackLine, "You corrected: Global.")
    }

    /// The correction is stored before anything is sent.
    func testCorrectStoresTextBeforeDelivery() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder)
        vm.beginCorrect(1826)
        XCTAssertEqual(vm.correcting?.canSend, false, "a blank correction cannot be sent")
        vm.correcting?.text = "  Global, one window for all.  "
        await vm.sendCorrection()
        XCTAssertEqual(recorder.calls, ["write", "deliver", "write"])
        XCTAssertEqual(recorder.writes, [.correct(1826, "Global, one window for all."), .correctionSent(1826)])
        XCTAssertNil(vm.correcting, "the sheet closes once the correction is stored")
    }

    /// A save that fails keeps the sheet open with the text and sends nothing.
    func testCorrectSaveFailureKeepsTheSheet() async {
        struct Broken: LocalizedError { var errorDescription: String? { "database is locked" } }
        let recorder = Recorder()
        let night = WatchmanNight(date: date("2026-11-16T12:00:00Z"), decided: [item()])
        var actions = WatchmanJournalViewModel.Actions.none
        actions.write = { _ in throw Broken() }
        actions.deliver = { _, _, _, _ in recorder.calls.append("deliver"); return .submitted }
        let vm = WatchmanJournalViewModel(read: { .init(nights: [night], deciding: []) }, actions: actions)
        vm.apply(.success(.init(nights: [night], deciding: [])))
        await correct(vm)
        XCTAssertEqual(vm.correcting?.text, "Global, one window for all.")
        XCTAssertEqual(vm.correcting?.error, "Couldn't save: database is locked")
        XCTAssertEqual(recorder.calls, [])
    }

    /// A live session gets the correction as a typed line (PROJ-12 gates in
    /// `SessionLineDelivery`), with what was decided before the owner's words.
    func testCorrectAliveSessionTypesLine() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder, delivery: .typed)
        vm.beginCorrect(1826)
        XCTAssertEqual(vm.correcting?.note,
                       "Your correction goes to session 3 as a typed line. Your answer also teaches Watchman.")
        vm.correcting?.text = "Global.\nOne window for all."
        await vm.sendCorrection()
        XCTAssertEqual(recorder.lines.map(\.sessionID), [3])
        XCTAssertEqual(recorder.lines.first?.itemID, 1826)
        XCTAssertEqual(recorder.lines.first?.line,
                       "Watchman decided \"Store the window per workbench or global?\" as \"Per workbench\" while I was "
                           + "away. My correction: Global. One window for all.")
        XCTAssertTrue(recorder.starts.isEmpty)
        XCTAssertEqual(vm.page?.decided.first?.sendLine, "Typed into session 3 — press Return there to send it")
        XCTAssertEqual(vm.page?.decided.first?.sendFailed, false)
    }

    /// An ended session: a new session starts on the item's target with the
    /// correction as its first instruction (D26). The journal has no arming
    /// path, so it stays unarmed unless the owner arms it.
    func testCorrectEndedSessionStartsUnarmedSession() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder, live: false, start: .success(42))
        vm.beginCorrect(1826)
        XCTAssertEqual(vm.correcting?.note, "Session 3 has ended, so a new session starts on #1801 with your "
            + "correction. Your answer also teaches Watchman.")
        vm.correcting?.text = "Global."
        await vm.sendCorrection()
        XCTAssertEqual(recorder.calls, ["write", "deliver", "start", "write"])
        XCTAssertEqual(recorder.writes.last, .correctionSent(1826))
        XCTAssertEqual(recorder.starts.map(\.item), [1826])
        XCTAssertTrue(recorder.starts.first?.line.hasSuffix("My correction: Global.") == true)
        XCTAssertEqual(vm.page?.decided.first?.sendLine, "Started session 42 with your correction")
        // Open session now opens the new session.
        vm.openSession(1826)
        XCTAssertEqual(recorder.routes, [WorkbenchRoute(projectID: 1, pane: .terminal, subjectID: 42)])
        // An item with no session and no target starts in its workbench.
        let none = model([item(session: 0, target: 0)], recorder: Recorder(), live: false)
        none.beginCorrect(1826)
        XCTAssertEqual(none.correcting?.note, "No session is running, so a new session starts on acme-api with your "
            + "correction. Your answer also teaches Watchman.")
    }

    /// A delivery that fails keeps the stored correction, says why, and
    /// Retry sends it again.
    func testCorrectDeliveryFailureKeepsTextAndOffersRetry() async {
        let recorder = Recorder()
        let failure = WatchmanCorrectionError(
            reason: WatchmanJournalViewModel.startFailure(.notOnBoard, targetID: 1801))
        let vm = model([item()], recorder: recorder, live: false, start: .failure(failure))
        await correct(vm)
        XCTAssertEqual(recorder.writes, [.correct(1826, "Global, one window for all.")])
        let card = vm.page?.decided.first
        XCTAssertEqual(card?.sendLine, "Not sent — target #1801 is not on a workbench board")
        XCTAssertEqual(card?.sendFailed, true)
        await vm.retrySend(1826)
        XCTAssertEqual(recorder.starts.count, 2)
        XCTAssertEqual(recorder.writes.count, 1, "Retry sends again; it never writes again")
        XCTAssertEqual(recorder.starts.last?.line, recorder.starts.first?.line)
    }

    /// A held line whose session stopped before it went fails with Retry.
    func testHeldCorrectionThatNeverWentOffersRetry() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder, delivery: .held)
        await correct(vm)
        XCTAssertEqual(vm.page?.decided.first?.sendLine,
                       "Waiting to go into session 3 — it is on a permission prompt")
        recorder.heldCallback?(.tried(.submitted))
        XCTAssertEqual(vm.page?.decided.first?.sendLine, "Sent to session 3")
        // Its session ended before it went: not sent, Retry offered.
        let stoppedRecorder = Recorder()
        let stopped = model([item()], recorder: stoppedRecorder, delivery: .held)
        await correct(stopped)
        stoppedRecorder.heldCallback?(.tried(.noSession))
        XCTAssertEqual(stopped.page?.decided.first?.sendLine, "Not sent — the session stopped before it went")
        XCTAssertEqual(stopped.page?.decided.first?.sendFailed, true)
    }

    /// Open session puts the item's session on its workbench page.
    func testOpenSessionSelectsSession() {
        let recorder = Recorder()
        let vm = model([item(), item(1827, session: 0, target: 0)], recorder: recorder)
        vm.openSession(1826)
        XCTAssertEqual(recorder.routes, [WorkbenchRoute(projectID: 1, pane: .terminal, subjectID: 3)])
        XCTAssertEqual(vm.page?.decided.last?.canOpen, false, "no session, no Open session")
        vm.openSession(1827)
        XCTAssertEqual(recorder.routes.count, 1)
    }

    /// Mark done writes check done; a failed save says so.
    func testMarkDoneWritesCheckDone() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder)
        await vm.markDone(1831)
        XCTAssertEqual(recorder.writes, [.checkDone(1831)])
        XCTAssertNil(vm.actionError)
        let failing = WatchmanJournalViewModel { .init(nights: [], deciding: []) }
        await failing.ok(1)
        XCTAssertEqual(failing.actionError, "Couldn't save: the journal is read-only here")
    }

    /// Fix 1: Mark done on a waiting card clears it (owner_done_at), not feedback.
    func testMarkDoneClearsAWaitingItem() async {
        let recorder = Recorder()
        let parked = item(1830, outcome: "parked")
        let night = WatchmanNight(date: date("2026-11-16T12:00:00Z"), waiting: [parked])
        var actions = WatchmanJournalViewModel.Actions.none
        actions.write = { recorder.writes.append($0); return true }
        let vm = WatchmanJournalViewModel(read: { .init(nights: [night], deciding: []) }, actions: actions)
        vm.apply(.success(.init(nights: [night], deciding: [])))
        XCTAssertEqual(vm.page?.waiting.first?.canMarkDone, true)
        XCTAssertEqual(vm.page?.waiting.first?.canJudge, false)
        await vm.markDone(1830)
        XCTAssertEqual(recorder.writes, [.ownerDone(1830)])
    }

    /// Fix 2: a correction stored but never delivered (the app quit) is Not
    /// sent on a fresh journal, with Retry; once delivered it is stored as sent.
    func testUnsentCorrectionAfterRelaunchOffersRetry() async {
        let recorder = Recorder()
        let unsent = item(feedback: "corrected", feedbackText: "Global.")
        let vm = model([unsent], recorder: recorder)
        let card = vm.page?.decided.first
        XCTAssertEqual(card?.sendLine, "Not sent — the app quit before it went")
        XCTAssertEqual(card?.sendFailed, true)
        XCTAssertEqual(card?.feedbackLine, "You corrected: Global.")
        await vm.retrySend(1826)
        XCTAssertEqual(recorder.lines.first?.line.hasSuffix("My correction: Global."), true)
        XCTAssertEqual(recorder.writes, [.correctionSent(1826)])
        XCTAssertEqual(vm.page?.decided.first?.sendLine, "Sent to session 3")
        let sent = model([item(feedback: "corrected", feedbackText: "Global.", sentAt: date("2026-11-17T08:00:00Z"))],
                         recorder: Recorder())
        XCTAssertNil(sent.page?.decided.first?.sendLine)
        XCTAssertEqual(sent.page?.decided.first?.sendFailed, false)
    }

    /// Fix 4: Retry only from Not sent; a second tap while it sends starts nothing.
    func testRetryWhileSendingStartsOneSession() async {
        final class Gate: @unchecked Sendable {
            var waiting: CheckedContinuation<Void, Never>?
            var starts = 0
        }
        let gate = Gate()
        let night = WatchmanNight(date: date("2026-11-16T12:00:00Z"),
                                  decided: [item(feedback: "corrected", feedbackText: "Global.")])
        var actions = WatchmanJournalViewModel.Actions.none
        actions.write = { _ in true }
        actions.startSession = { _, _ in
            gate.starts += 1
            await withCheckedContinuation { gate.waiting = $0 }
            return 42
        }
        let vm = WatchmanJournalViewModel(read: { .init(nights: [night], deciding: []) }, actions: actions)
        vm.apply(.success(.init(nights: [night], deciding: [])))
        let first = Task { await vm.retrySend(1826) }
        for _ in 0..<1000 where gate.waiting == nil { await Task.yield() }
        XCTAssertEqual(vm.page?.decided.first?.sendLine, "Sending your correction…")
        await vm.retrySend(1826)
        XCTAssertEqual(gate.starts, 1, "a second Retry while sending does nothing")
        gate.waiting?.resume()
        await first.value
        XCTAssertEqual(vm.page?.decided.first?.sendLine, "Started session 42 with your correction")
        await vm.retrySend(1826)
        XCTAssertEqual(gate.starts, 1, "nothing to retry once it went")
    }

    /// Fix 5: Cancel does nothing while the correction is being saved.
    func testCancelIsOffWhileSaving() {
        let vm = model([item()], recorder: Recorder())
        vm.beginCorrect(1826)
        XCTAssertEqual(vm.correcting?.canCancel, true)
        vm.correcting?.saving = true
        XCTAssertEqual(vm.correcting?.canCancel, false)
        vm.cancelCorrect()
        XCTAssertNotNil(vm.correcting)
        vm.correcting?.saving = false
        vm.cancelCorrect()
        XCTAssertNil(vm.correcting)
    }

    /// Fix 6: a decision judged elsewhere keeps the sheet and the text, says so, sends nothing.
    func testCorrectAlreadyJudgedKeepsTheSheet() async {
        let recorder = Recorder()
        let vm = model([item()], recorder: recorder, writes: false)
        await correct(vm)
        XCTAssertEqual(vm.correcting?.text, "Global, one window for all.")
        XCTAssertEqual(vm.correcting?.error, "This decision was already judged; your text is kept here.")
        XCTAssertEqual(vm.correcting?.saving, false)
        XCTAssertEqual(recorder.calls, ["write"])
    }

    func testStartFailureReasons() {
        XCTAssertEqual(WatchmanJournalViewModel.startFailure(.inProgress, targetID: 7),
                       "a session on target #7 is starting right now")
        XCTAssertEqual(WatchmanJournalViewModel.startFailure(.failed("Could not read the target: x"), targetID: 7),
                       "Could not read the target: x")
        XCTAssertEqual(WatchmanJournalViewModel.startFailure(.agentNotFound(.codex), targetID: 7),
                       "Codex was not found on this Mac")
        XCTAssertEqual(WatchmanJournalViewModel.startFailure(.cleaningUp, targetID: 7), "the session is being deleted")
        XCTAssertEqual(WatchmanJournalViewModel.startFailure(.unsupportedAgent("gemini"), targetID: 7),
                       "this version cannot start a gemini session")
    }
}
