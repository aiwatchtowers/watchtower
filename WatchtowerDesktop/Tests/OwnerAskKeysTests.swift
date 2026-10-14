import AppKit
import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answering an ask from the keyboard (owner ask #90): ⌘↩ in a drawer
/// field presses the answer button a click would — Answer, Send, Approve —
/// and ⌘⇧↩ a review's Request changes, each only while that button is
/// enabled; `OwnerAskKeyCatcher` takes the keys while no field has the
/// keyboard, and leaves them to any field that does.
@MainActor
final class OwnerAskKeysTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var project: Int64 = 0

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
    nonisolated private static let checklist = #"{"checklist":[{"id":"1","text":"Launch"}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        project = try pool.write { try TestDatabase.insertWorkbench($0, folder: "/tmp/acme") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ kind: String, payload: String) async throws -> (WorkbenchesViewModel, OwnerAsk) {
        let project = project
        let id = try await pool.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: project, kind: kind, payload: payload,
                                            docPath: kind == "review" ? "docs/plan.md" : "")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskKeysTests-\(UUID().uuidString)"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.asks.load(projectID: project)
        return (vm, try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id }))
    }

    private func editors(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk) throws -> [CommentTextEditor] {
        try OwnerAskDrawer(vm: vm, ask: ask).inspect().findAll(CommentTextEditor.self).map { try $0.actualView() }
    }

    private func button(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk, _ label: String) throws -> InspectableView<ViewType.Button> {
        try OwnerAskDrawer(vm: vm, ask: ask).inspect().find(button: label)
    }

    /// The stored ask once its answer is written (the answer reloads the
    /// open asks last).
    private func answered(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk) async throws -> OwnerAsk? {
        let deadline = Date().addingTimeInterval(5)
        while vm.asks.openAsks[project]?.contains(where: { $0.id == ask.id }) == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let project = project
        return try await pool.read { try OwnerAskQueries.ask($0, id: ask.id, projectID: project) }
    }

    private func assertNothingSent(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(vm.asks.isAnswering(ask.id), file: file, line: line)
        let project = project
        let stored = try await pool.read { try OwnerAskQueries.ask($0, id: ask.id, projectID: project) }
        XCTAssertEqual(stored?.isOpen, true, "nothing was answered", file: file, line: line)
    }

    // MARK: - From a field

    func testCommandReturnAnswersAQuestionOnlyOnceTheButtonIsOn() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        XCTAssertTrue(try button(vm, ask, "Answer").isDisabled())
        let all = try editors(vm, ask)
        let (other, note) = (all[0], all[1])
        other.onSubmit?()
        note.onSubmit?()
        XCTAssertNil(vm.asks.pressKey(on: ask, shift: false))
        try await assertNothingSent(vm, ask)

        vm.asks.editDraft(ask.id) { $0.picks["a"] = .init(labels: ["Yes"]) }
        XCTAssertFalse(try button(vm, ask, "Answer").isDisabled())
        note.onShiftSubmit?()
        try await assertNothingSent(vm, ask)  // ⌘⇧↩ names no button of a question
        try editors(vm, ask)[0].onSubmit?()

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.answers.first?.labels, ["Yes"])
    }

    func testCommandReturnSendsACheckWithTheSendButtonsEnablement() async throws {
        let (vm, ask) = try await makeVM("check", payload: Self.checklist)
        vm.asks.editDraft(ask.id) { $0.checks["1"] = .broken }
        XCTAssertTrue(try button(vm, ask, "Send").isDisabled(), "a broken item needs its note")
        let itemNote = try XCTUnwrap(try editors(vm, ask).first)
        XCTAssertEqual(itemNote.placeholder, "What happened?")
        itemNote.onSubmit?()
        try await assertNothingSent(vm, ask)

        vm.asks.editDraft(ask.id) { $0.checkNotes["1"] = "Crashes" }
        try XCTUnwrap(try editors(vm, ask).last).onSubmit?()

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.checklist.first?.state, .broken)
        XCTAssertEqual(stored?.answer?.checklist.first?.note, "Crashes")
    }

    func testCommandReturnApprovesAReview() async throws {
        let (vm, ask) = try await makeVM("review", payload: "{}")
        let help = try button(vm, ask, "Approve").help().string()
        XCTAssertEqual(help, "Shortcut: ⌘↩")
        XCTAssertEqual(try button(vm, ask, "Request changes").help().string(), "Shortcut: ⌘⇧↩")
        try XCTUnwrap(try editors(vm, ask).last).onSubmit?()

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.verdict, .approved)
    }

    func testCommandShiftReturnRequestsChangesOnAReview() async throws {
        let (vm, ask) = try await makeVM("review", payload: "{}")
        vm.asks.editDraft(ask.id) { $0.note = "Split the plan" }
        try XCTUnwrap(try editors(vm, ask).last).onShiftSubmit?()

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.verdict, .changes, "never inferred from the draft: the key names the verdict")
    }

    /// A review whose question is unanswered: Approve is off, so ⌘↩
    /// changes nothing — not even the draft's verdict.
    func testADisabledApproveTakesNoKey() async throws {
        let (vm, ask) = try await makeVM("review", payload: Self.questions)
        XCTAssertTrue(try button(vm, ask, "Approve").isDisabled())
        let note = try XCTUnwrap(try editors(vm, ask).last)
        note.onSubmit?()
        note.onShiftSubmit?()
        try await assertNothingSent(vm, ask)
        XCTAssertNil(vm.asks.drafts.askDraft(for: ask.id).verdict)
    }

    func testNoKeyAnswersWhileAnAnswerIsWritten() async throws {
        let (vm, ask) = try await makeVM("review", payload: "{}")
        // Holds the writer, so the answer's write waits mid-flight.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pool = try XCTUnwrap(self.pool)
        DispatchQueue.global().async {
            try? pool.write { _ in
                held.signal()
                release.wait()
            }
        }
        held.wait()

        let first = try XCTUnwrap(vm.asks.pressKey(on: ask, shift: false))
        let deadline = Date().addingTimeInterval(5)
        while !vm.asks.isAnswering(ask.id), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(vm.asks.pressKey(on: ask, shift: true), "the buttons are off while the first answer is written")
        release.signal()
        await first.value

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.verdict, .approved)
    }

    // MARK: - With no field focused

    private func key(_ window: NSWindow, _ flags: NSEvent.ModifierFlags, repeat isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: isARepeat,
                                       keyCode: CommentEditorKeys.returnKeyCode))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    /// A field and read-only text beside the drawer (a target comment, a
    /// chat transcript), and in the drawer a field of its own and read-only
    /// text (a review's document).
    func testTheCatcherTakesTheKeysOnlyWhileNoFieldHasTheKeyboard() throws {
        var keys: [Bool] = []
        var outsideSent = 0
        var insideSent = 0
        // Labelled: a trailing closure would be `onFocus`.
        // swiftlint:disable trailing_closure
        let root = HStack(spacing: 0) {
            VStack {
                CommentTextEditor(text: .constant(""), onSubmit: { outsideSent += 1 })
                ReadOnlyText()
            }
            .frame(width: 200)
            VStack {
                CommentTextEditor(text: .constant(""), onSubmit: { insideSent += 1 })
                ReadOnlyText()
            }
            .frame(width: 200)
            .background(OwnerAskKeyCatcher { keys.append($0) })
        }
        // swiftlint:enable trailing_closure
        let host = NSHostingView(rootView: root.frame(width: 400, height: 240))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let views = textViews(in: host)
        let outside = try XCTUnwrap(views.first { $0.isEditable && $0.convert($0.bounds, to: nil).minX < 200 })
        let inside = try XCTUnwrap(views.first { $0.isEditable && $0.convert($0.bounds, to: nil).minX >= 200 })
        let document = try XCTUnwrap(views.first { !$0.isEditable && $0.convert($0.bounds, to: nil).minX >= 200 })
        let transcript = try XCTUnwrap(views.first { !$0.isEditable && $0.convert($0.bounds, to: nil).minX < 200 })

        window.makeFirstResponder(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, [.command, .shift])))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(window, [.command, .option])), "⌘⌥↩ is the code question's")
        XCTAssertEqual(keys, [false, true])

        XCTAssertTrue(window.makeFirstResponder(document))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertEqual(keys, [false, true, false], "the drawer's own read-only text")

        XCTAssertTrue(window.makeFirstResponder(transcript))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertEqual(keys, [false, true, false], "read-only text outside the drawer keeps the key")

        XCTAssertTrue(window.makeFirstResponder(inside))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertTrue(window.makeFirstResponder(outside))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertEqual(keys, [false, true, false], "a focused field keeps its ⌘↩")
        XCTAssertEqual(insideSent, 1)
        XCTAssertEqual(outsideSent, 1)
    }

    /// A ⌘↩ held past leaving a margin comment: its auto-repeat reaches
    /// the catcher with nothing focused and must not answer the ask.
    func testAHeldKeysRepeatAnswersNothing() throws {
        var keys: [Bool] = []
        let host = NSHostingView(rootView: Color.clear.frame(width: 200, height: 100)
            .background(OwnerAskKeyCatcher { keys.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        window.makeFirstResponder(nil)
        XCTAssertNil(OwnerAskKeyCatcher.answerKey(try key(window, .command, repeat: true)))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(window, .command, repeat: true)))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(window, [.command, .shift], repeat: true)))
        XCTAssertEqual(keys, [], "a repeat falls through")
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertEqual(keys, [false], "a fresh press still answers")
    }

    // MARK: - After a click in the drawer (board #536)

    /// A drawer beside a terminal holding the keyboard, as on the workbench
    /// page: the terminal on the left, the drawer on the right, in a host
    /// that can take it down (`shown`).
    private struct Page {
        let window: NSWindow
        let terminal: TerminalLike
        let drawer: NSView
        let catcher: OwnerAskKeyCatcher.CatcherView
        let shown: DrawerShown
    }

    private func page(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk) throws -> Page {
        let shown = DrawerShown()
        let terminal = TerminalLike(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let drawer = NSHostingView(rootView: RemovableDrawer(shown: shown, vm: vm, ask: ask).frame(width: 320, height: 400))
        drawer.frame = NSRect(x: 200, y: 0, width: 320, height: 400)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        content.addSubview(terminal)
        content.addSubview(drawer)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        drawer.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let catcher = try XCTUnwrap(catchers(in: drawer).first)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        return Page(window: window, terminal: terminal, drawer: drawer, catcher: catcher, shown: shown)
    }

    private func catchers(in view: NSView) -> [OwnerAskKeyCatcher.CatcherView] {
        if let catcher = view as? OwnerAskKeyCatcher.CatcherView { return [catcher] }
        return view.subviews.flatMap { catchers(in: $0) }
    }

    /// A left click at `point` as the app sees it: the catcher's monitor
    /// first, then AppKit handling it — giving the keyboard to `taker`
    /// when the click hit a view that takes it — then the main queue's next
    /// turn, which comes before any key the owner presses. Waits by
    /// sleeping: this test runs on the main queue, which a nested run loop
    /// does not drain.
    private func click(_ page: Page, at point: NSPoint, taker: NSResponder? = nil) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: page.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        page.catcher.clicked(event)
        if let taker { XCTAssertTrue(page.window.makeFirstResponder(taker)) }
        try await Task.sleep(for: .milliseconds(50))
    }

    /// The drawer's host taking it down for real (`dismantleNSView`), then
    /// the main queue's turns after it.
    private func removeDrawer(_ page: Page) async throws {
        page.shown.isOn = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(catchers(in: page.drawer).isEmpty, "the catcher is gone")
    }

    private static let inDrawer = NSPoint(x: 360, y: 200)
    private static let onTerminal = NSPoint(x: 100, y: 200)

    /// The owner's case: the terminal has the keyboard, a click picks an
    /// option (AppKit leaves the keyboard with the terminal: the option
    /// takes no focus), and ⌘↩ right after answers — no click in a field.
    func testAClickOnAnOptionThenCommandReturnAnswers() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        XCTAssertFalse(page.window.performKeyEquivalent(with: try key(page.window, .command)), "the terminal's ⌘↩")

        try await click(page, at: Self.inDrawer)
        vm.asks.editDraft(ask.id) { $0.picks["a"] = .init(labels: ["Yes"]) }  // what the option's button does
        XCTAssertTrue(page.window.firstResponder === page.window, "the click took the keyboard to the drawer")
        XCTAssertTrue(page.window.performKeyEquivalent(with: try key(page.window, .command)))

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.answers.first?.labels, ["Yes"])
    }

    /// Marking a check's step with the mouse, then ⌘↩: sent.
    func testAClickOnAStepThenCommandReturnSendsTheCheck() async throws {
        let (vm, ask) = try await makeVM("check", payload: Self.checklist)
        let page = try page(vm, ask)
        defer { page.window.close() }

        try await click(page, at: Self.inDrawer)
        vm.asks.editDraft(ask.id) { $0.checks["1"] = .ok }
        XCTAssertTrue(page.window.performKeyEquivalent(with: try key(page.window, .command)))

        let stored = try await answered(vm, ask)
        XCTAssertEqual(stored?.answer?.checklist.first?.state, .ok)
    }

    /// The button still off after the click (nothing picked): the key
    /// presses nothing.
    func testAClickLeavesADisabledButtonOff() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }

        try await click(page, at: Self.inDrawer)
        _ = page.window.performKeyEquivalent(with: try key(page.window, .command))
        try await assertNothingSent(vm, ask)
    }

    /// A click on the terminal leaves it the keyboard and its ⌘↩.
    func testAClickOnTheTerminalKeepsItsCommandReturn() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        vm.asks.editDraft(ask.id) { $0.picks["a"] = .init(labels: ["Yes"]) }
        let page = try page(vm, ask)
        defer { page.window.close() }

        try await click(page, at: Self.onTerminal, taker: page.terminal)
        XCTAssertTrue(page.window.firstResponder === page.terminal)
        XCTAssertFalse(page.window.performKeyEquivalent(with: try key(page.window, .command)))
        try await assertNothingSent(vm, ask)
    }

    /// A drag on the drawer's resize handle is no click into it: the
    /// terminal keeps the keyboard.
    func testADragOnTheResizeHandleKeepsTheTerminalsKeyboard() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let edge = page.catcher.convert(page.catcher.bounds, to: nil).minX

        try await click(page, at: NSPoint(x: edge + PanelResizeHandle.thickness - 1, y: 200))
        XCTAssertTrue(page.window.firstResponder === page.terminal)
        try await click(page, at: NSPoint(x: edge + PanelResizeHandle.thickness + 1, y: 200))
        XCTAssertTrue(page.window.firstResponder === page.window, "just past the handle: the drawer's")
    }

    /// A click in the drawer that put the keyboard in its own field (or
    /// the document) leaves it there; the field's ⌘↩ is its own.
    func testAClickInTheDrawerLeavesItsFieldTheKeyboard() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let field = try XCTUnwrap(textViews(in: page.drawer).first { $0.isEditable })

        try await click(page, at: Self.inDrawer, taker: field)
        XCTAssertTrue(page.window.firstResponder === field)
    }

    /// Full Keyboard Access: the click gives the keyboard to the control
    /// it hit, inside the drawer. The control lets go, and the terminal —
    /// not the control — gets the keyboard back when the drawer goes.
    func testAControlInTheDrawerTakingTheKeyboardLetsGoAndTheTerminalGetsItBack() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let control = TerminalLike(frame: NSRect(x: 340, y: 190, width: 40, height: 20))
        page.window.contentView?.addSubview(control)

        try await click(page, at: Self.inDrawer, taker: control)
        XCTAssertTrue(page.window.firstResponder === page.window)
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === page.terminal)
    }

    /// An expanded drawer over its session's terminal (kept underneath,
    /// transparent): the terminal under it is no part of the drawer, so
    /// the click lends its keyboard and the drawer going hands it back.
    func testACoveredTerminalGetsTheKeyboardBack() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let container = TerminalContainerView(frame: page.drawer.frame)
        let covered = TerminalLike(frame: container.bounds)
        container.addSubview(covered)
        container.alphaValue = 0
        page.window.contentView?.addSubview(container, positioned: .below, relativeTo: page.drawer)

        XCTAssertTrue(page.window.makeFirstResponder(covered))
        try await click(page, at: Self.inDrawer)
        XCTAssertTrue(page.window.firstResponder === page.window, "the click took the keyboard to the drawer")
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === covered)
    }

    /// A field beside the drawer (a target comment) holding the keyboard:
    /// the click in the drawer takes it, so ⌘↩ answers, not sends that comment.
    func testAClickInTheDrawerTakesTheKeyboardFromAFieldBesideIt() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let comment = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        page.window.contentView?.addSubview(comment)

        XCTAssertTrue(page.window.makeFirstResponder(comment))
        try await click(page, at: Self.inDrawer)
        XCTAssertTrue(page.window.firstResponder === page.window)
    }

    /// The answer button: the click takes the keyboard on the next turn,
    /// the answered session's terminal takes it later (`showAnsweredSession`
    /// → `requestKeyboardFocus`, after the answer is written and delivered),
    /// and the drawer going leaves it there. Keyboard the click itself
    /// moved out of the drawer is never taken.
    func testTheAnsweredSessionsTerminalEndsWithTheKeyboard() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let sessionTerminal = TerminalLike(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        page.window.contentView?.addSubview(sessionTerminal)

        try await click(page, at: Self.inDrawer)
        XCTAssertTrue(page.window.firstResponder === page.window)
        XCTAssertTrue(page.window.makeFirstResponder(sessionTerminal))
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === sessionTerminal)

        let other = try self.page(vm, ask)
        defer { other.window.close() }
        let moved = TerminalLike(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        other.window.contentView?.addSubview(moved)
        try await click(other, at: Self.inDrawer, taker: moved)
        XCTAssertTrue(other.window.firstResponder === moved, "moved out of the drawer by the click: left there")
    }

    /// The drawer going (its catcher really taken down) hands the keyboard
    /// back to the terminal a click in it took it from.
    func testTheDrawerGoingHandsTheKeyboardBack() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }

        try await click(page, at: Self.inDrawer)
        XCTAssertTrue(page.window.firstResponder === page.window)
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === page.terminal, "handed back")
    }

    /// J / K or "k of N ›" to another session's ask moves the drawer to
    /// that session's host: this catcher goes, but the drawer stays, so the
    /// keyboard is not handed back — the next bare key must not land in
    /// this terminal's agent.
    func testTheDrawerMovingToAnotherHostHandsNothingBack() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }

        try await click(page, at: Self.inDrawer)
        vm.asks.openDrawer(askID: ask.id + 1, projectID: project)
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === page.window)
    }

    /// The owner put the keyboard somewhere since: left alone.
    func testTheDrawerGoingLeavesAKeyboardTakenSince() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }
        let other = TerminalLike(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        page.window.contentView?.addSubview(other)

        try await click(page, at: Self.inDrawer)
        try await click(page, at: Self.onTerminal, taker: other)
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === other)
    }

    /// A click outside that takes no keyboard (a stack card, a Quick
    /// option) keeps the loan: the terminal still gets it back.
    func testAClickOutsideTakingNoKeyboardKeepsTheLoan() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)
        defer { page.window.close() }

        try await click(page, at: Self.inDrawer)
        try await click(page, at: Self.onTerminal)
        XCTAssertTrue(page.window.firstResponder === page.window)
        try await removeDrawer(page)
        XCTAssertTrue(page.window.firstResponder === page.terminal)
    }

    /// The terminal gone with its window first: the drawer going hands
    /// nothing back, and nothing breaks.
    func testTheDrawerGoingAfterTheTerminalsWindowHandsNothingBack() async throws {
        let (vm, ask) = try await makeVM("question", payload: Self.questions)
        let page = try page(vm, ask)

        try await click(page, at: Self.inDrawer)
        page.window.close()
        page.terminal.removeFromSuperview()
        try await removeDrawer(page)
        XCTAssertNil(page.terminal.window)
        XCTAssertFalse(page.window.firstResponder === page.terminal)
    }
}

/// Whether `RemovableDrawer` shows its drawer.
@Observable
private final class DrawerShown {
    var isOn = true
}

/// A drawer host the test can take the drawer out of.
private struct RemovableDrawer: View {
    let shown: DrawerShown
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk

    var body: some View {
        if shown.isOn {
            OwnerAskDrawer(vm: vm, ask: ask)
        } else {
            Color.clear
        }
    }
}

/// Takes the keyboard and nothing else, as a terminal does.
private final class TerminalLike: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Selectable, not editable: a review document's text view.
private struct ReadOnlyText: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        view.string = "The plan"
        view.isEditable = false
        view.isSelectable = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {}
}
