import AppKit
import GRDB
import SwiftUI
import WebKit
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Owner asks without the mouse (board #412): the bare keys of the page,
/// the drawer and a Quick ask's banner or card, the catcher's gate, and
/// ⌘↩ / ⌘⇧↩ unchanged.
@MainActor
final class OwnerAskKeyNavigationTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var project: Int64 = 0

    nonisolated private static let quick = #"{"questions":[{"id":"1","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#
    nonisolated private static let twoQuestions = #"""
    {"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]},
                  {"id":"b","question":"Which?","multi":true,"options":[{"label":"X"},{"label":"Y"},{"label":"Z"}]}]}
    """#
    nonisolated private static let checklist = #"{"checklist":[{"id":"1","text":"Launch"},{"id":"2","text":"Quit"}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        project = try pool.write { try TestDatabase.insertWorkbench($0, folder: "/tmp/acme") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func insert(_ kind: String, payload: String, level: String = "full", sessionID: Int64? = nil) async throws -> Int64 {
        let project = project
        return try await pool.write { db in
            let id = try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: sessionID, kind: kind, payload: payload,
                                                     docPath: kind == "review" ? "docs/plan.md" : "")
            try db.execute(sql: "UPDATE owner_asks SET level = ? WHERE id = ?", arguments: [level, id])
            return id
        }
    }

    private func makeVM(center: TerminalCenter? = nil) throws -> WorkbenchesViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskKeyNavigationTests-\(UUID().uuidString)"))
        return WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults, terminalCenter: center)
    }

    private func loaded(_ vm: WorkbenchesViewModel, _ id: Int64) async throws -> OwnerAsk {
        await vm.asks.load(projectID: project)
        return try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id })
    }

    private func stored(_ id: Int64) async throws -> OwnerAsk? {
        let project = project
        return try await pool.read { try OwnerAskQueries.ask($0, id: id, projectID: project) }
    }

    /// The stored ask once an answer started by a key is written.
    private func answered(_ id: Int64) async throws -> OwnerAsk? {
        let deadline = Date().addingTimeInterval(5)
        while try await stored(id)?.isOpen == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await stored(id)
    }

    private func digit(_ character: Character) -> OwnerAskKeyMap.Press {
        OwnerAskKeyMap.Press(key: .character(character))
    }

    private final class Box {
        var focused = true
        var opened = 0
        var released = 0
        var moves: [Bool] = []
        var textHasKeyboard = false
    }

    private func cardKeys(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk, _ box: Box, release: @escaping () -> Void = {}) -> OwnerAskCardKeys {
        OwnerAskCardKeys(vm: vm, ask: ask) {
            box.focused
        } open: {
            box.opened += 1
        } release: {
            box.released += 1
            box.focused = false
            release()
        } move: { forward in
            box.moves.append(forward)
            return true
        } textHasKeyboard: {
            box.textHasKeyboard
        }
    }

    // MARK: - Banner and stack card

    /// Spec 2026-10-10 Part 9.4: 1–3 answer a Quick ask only while its
    /// banner (or card) holds the keyboard, through the tap's own
    /// `answerQuick` (PROJ-12 store-then-deliver) — the same stored answer
    /// as a click on that option.
    func testDigitPicksAQuickOptionOnlyWithTheBannerFocused() async throws {
        let keyed = try await insert("question", payload: Self.quick, level: "quick")
        let clicked = try await insert("question", payload: Self.quick, level: "quick")
        let vm = try makeVM()
        let ask = try await loaded(vm, keyed)
        let box = Box()
        let banner = cardKeys(vm, ask, box)

        box.focused = false
        XCTAssertFalse(banner.press(digit("1")), "a digit typed in the terminal is the terminal's")
        XCTAssertFalse(banner.press(OwnerAskKeyMap.Press(key: .returnKey)))
        box.focused = true
        XCTAssertFalse(banner.press(digit("3")), "two options: 3 picks nothing")
        let open = try await stored(keyed)
        XCTAssertEqual(open?.isOpen, true, "nothing answered yet")
        XCTAssertEqual(box.opened, 0)

        XCTAssertTrue(banner.press(digit("1")))
        let viaKey = try await answered(keyed)
        let row = try XCTUnwrap(OwnerAskQuickRow(ask: ask))
        let clickedAsk = try await loaded(vm, clicked)
        _ = await vm.answerQuick(clickedAsk, with: row.answer(picking: row.choices[0].label))
        let viaClick = try await stored(clicked)

        XCTAssertEqual(viaKey?.isOpen, false)
        XCTAssertEqual(viaKey?.answer, viaClick?.answer, "the click's answer, byte for byte")
        XCTAssertEqual(viaKey?.answer?.answers.first?.labels, ["Yes"])
    }

    func testReturnOpensAndAFullAsksCardAnswersNothing() async throws {
        let id = try await insert("question", payload: Self.quick)
        let vm = try makeVM()
        let ask = try await loaded(vm, id)
        let box = Box()
        let card = cardKeys(vm, ask, box)

        XCTAssertFalse(card.press(digit("1")), "a Full ask has no one-tap row")
        XCTAssertTrue(card.press(digit("j")))
        XCTAssertTrue(card.press(OwnerAskKeyMap.Press(key: .upArrow)))
        XCTAssertEqual(box.moves, [true, false])
        XCTAssertTrue(card.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(box.opened, 1)
        XCTAssertEqual(box.released, 1, "Return lets go of the keyboard")
        let stillOpen = try await stored(id)
        XCTAssertEqual(stillOpen?.isOpen, true)
    }

    /// K3: the Reply field (a text view with the keyboard) keeps every key.
    func testTypingInTheReplyFieldNeitherAnswersNorMoves() async throws {
        let id = try await insert("question", payload: Self.quick, level: "quick")
        let vm = try makeVM()
        let ask = try await loaded(vm, id)
        let box = Box()
        box.textHasKeyboard = true
        let card = cardKeys(vm, ask, box)

        XCTAssertFalse(card.press(digit("1")))
        XCTAssertFalse(card.press(digit("j")))
        XCTAssertFalse(card.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(box.moves, [])
        XCTAssertEqual(box.opened, 0)
        let stillOpen = try await stored(id)
        XCTAssertEqual(stillOpen?.isOpen, true)
        XCTAssertFalse(vm.asks.isAnswering(id))
    }

    func testATextFieldsEditorCountsAsTextWithTheKeyboard() throws {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let plain = FocusableView(frame: NSRect(x: 0, y: 30, width: 100, height: 20))
        let window = makeWindow(views: [field, plain])
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(OwnerAskCardKeys.textHasKeyboard(in: window), "the field editor has it")
        XCTAssertTrue(window.makeFirstResponder(plain))
        XCTAssertFalse(OwnerAskCardKeys.textHasKeyboard(in: window))
        XCTAssertFalse(OwnerAskCardKeys.textHasKeyboard(in: nil))
    }

    /// K2: Return on a card opens the drawer and lets go of the keyboard,
    /// so ⌘↩ reaches the drawer's catcher, and a digit after it answers
    /// nothing on the card.
    func testReturnOnACardHandsTheKeysToTheDrawer() async throws {
        let id = try await insert("question", payload: Self.quick, level: "quick")
        let vm = try makeVM()
        let ask = try await loaded(vm, id)
        var answerKeys: [Bool] = []
        let card = FocusableView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        let catcher = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 60, y: 0, width: 140, height: 100))
        catcher.onKey = { answerKeys.append($0) }
        let window = makeWindow(views: [card, catcher])
        defer { window.close() }
        let box = Box()
        let keys = cardKeys(vm, ask, box) {
            OwnerAskCardKeys.releaseKeyboard(in: window)
        }

        XCTAssertTrue(window.makeFirstResponder(card))
        XCTAssertFalse(window.performKeyEquivalent(with: try commandReturn(window)), "the card has the keyboard")
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .returnKey)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(window.firstResponder === window, "nothing has the keyboard")
        XCTAssertTrue(window.performKeyEquivalent(with: try commandReturn(window)))
        XCTAssertEqual(answerKeys, [false])

        XCTAssertFalse(keys.press(digit("1")), "the card no longer holds the keyboard")
        let stillOpen = try await stored(id)
        XCTAssertEqual(stillOpen?.isOpen, true)
    }

    func testAChoiceNamesItsKey() {
        XCTAssertEqual(OwnerAskCardKeys.hint("Remove the flag", index: 0), "Remove the flag (press 1)")
        XCTAssertEqual(OwnerAskCardKeys.hint("Later", index: 3), "Later", "1–3 only")
    }

    // MARK: - The page

    func testAOpensTheStackOnlyWithAnAskWaitingAtLevelTwo() async throws {
        let vm = try makeVM()
        await vm.reload()
        vm.drill(into: project)
        vm.panelVisible = false
        await vm.asks.load(projectID: project)
        XCTAssertFalse(vm.openStackFromKeyboard(), "no ask waits: A is left alone")
        XCTAssertNil(vm.asks.stackKeyboardRequest)

        _ = try await insert("question", payload: Self.quick)
        await vm.asks.load(projectID: project)
        vm.drilledWorkbenchID = nil
        XCTAssertFalse(vm.openStackFromKeyboard(), "level 1 shows no stack: A is not taken")
        XCTAssertNil(vm.asks.stackKeyboardRequest, "and leaves no request behind")
        XCTAssertFalse(vm.panelVisible)

        vm.drill(into: project)
        XCTAssertTrue(vm.openStackFromKeyboard())
        XCTAssertTrue(vm.panelVisible, "the panel comes back to show the stack")
        XCTAssertEqual(vm.asks.stackKeyboardRequest?.projectID, project)
    }

    /// K10: the open palette keeps every key.
    func testThePageTakesNothingUnderThePalette() async throws {
        let vm = try makeVM()
        await vm.reload()
        vm.drill(into: project)
        _ = try await insert("question", payload: Self.quick)
        await vm.asks.load(projectID: project)
        let a = OwnerAskKeyMap.Press(key: .character("a"))

        XCTAssertFalse(WorkbenchTitleRow.pressOnPage(a, vm: vm, paletteOpen: true))
        XCTAssertNil(vm.asks.stackKeyboardRequest)
        XCTAssertFalse(WorkbenchTitleRow.pressOnPage(digit("j"), vm: vm, paletteOpen: false))
        XCTAssertTrue(WorkbenchTitleRow.pressOnPage(a, vm: vm, paletteOpen: false))
        XCTAssertNotNil(vm.asks.stackKeyboardRequest)
    }

    /// K4/K10: a request is its workbench's, taken once, and only fresh.
    func testTheStackRequestIsTakenOnceByItsOwnWorkbench() throws {
        let vm = try makeVM()
        let now = Date()
        vm.asks.requestStackKeyboard(projectID: 1, now: now)

        XCTAssertFalse(vm.asks.takeStackKeyboardRequest(projectID: 2, now: now), "another workbench's section")
        XCTAssertNotNil(vm.asks.stackKeyboardRequest, "stays for its own")
        XCTAssertTrue(vm.asks.takeStackKeyboardRequest(projectID: 1, now: now))
        XCTAssertFalse(vm.asks.takeStackKeyboardRequest(projectID: 1, now: now), "once")

        vm.asks.requestStackKeyboard(projectID: 1, now: now)
        let later = now.addingTimeInterval(OwnerAsksViewModel.stackKeyboardWindow + 1)
        XCTAssertFalse(vm.asks.takeStackKeyboardRequest(projectID: 1, now: later), "a stale request moves nothing")
        XCTAssertNil(vm.asks.stackKeyboardRequest)
    }

    // MARK: - Switching asks from the keyboard (K1)

    /// J to another session's ask puts its terminal on screen without the
    /// keyboard: stray keys there would become an owner draft and stop the
    /// PROJ-12 auto-submit.
    func testAKeyboardSwitchLeavesTheTerminalWithoutTheKeyboard() async throws {
        let (first, second) = try await pool.write { [project] db in
            let one = try TerminalSessionQueries.create(db, .init(projectID: project, kind: .shell, title: "one", folderPath: "/tmp/acme"))
            let two = try TerminalSessionQueries.create(db, .init(projectID: project, kind: .shell, title: "two", folderPath: "/tmp/acme"))
            return (one.id, two.id)
        }
        let center = TerminalCenter()
        let vm = try makeVM(center: center)
        await vm.reload()
        vm.drill(into: project)
        let firstAsk = try await insert("question", payload: Self.twoQuestions, sessionID: first)
        let secondAsk = try await insert("question", payload: Self.twoQuestions, sessionID: second)
        let ask = try await loaded(vm, firstAsk)
        vm.asks.setDrawerKeysActive(true, projectID: project)
        let box = CursorBox()

        XCTAssertTrue(drawerKeys(vm, ask, box).press(digit("j")))
        let deadline = Date().addingTimeInterval(5)
        while !vm.layout(projectID: project).visiblePanes.contains(.session(second)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(center.takeKeepKeyboard(second), "its attach leaves the keyboard alone")
        XCTAssertFalse(center.takeKeepKeyboard(second), "once")
        XCTAssertFalse(TerminalHostAttachment.needsFocus(attached: true, requested: nil, honoured: nil, keepsKeyboard: true))
        XCTAssertTrue(TerminalHostAttachment.needsFocus(attached: true, requested: 2, honoured: 1, keepsKeyboard: true),
                      "an explicit request still focuses")

        await vm.showAsk(firstAsk, projectID: project)
        XCTAssertFalse(center.takeKeepKeyboard(first), "a click's switch focuses the terminal as before")
        _ = secondAsk
    }

    func testKeepKeyboardExpires() {
        let center = TerminalCenter()
        let now = Date()
        center.keepKeyboardOnAttach(4, now: now)
        XCTAssertFalse(center.takeKeepKeyboard(4, now: now.addingTimeInterval(TerminalCenter.keepKeyboardWindow + 1)),
                       "an attach that never came does not hold a later one")
        XCTAssertFalse(center.takeKeepKeyboard(5, now: now))
    }

    // MARK: - The drawer

    private final class CursorBox {
        var cursor: Int?
        var field: OwnerAskFieldFocus?
        var comment: OwnerAskCommentStep?
    }

    private func drawerKeys(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk, _ box: CursorBox, editable: Bool = true) -> OwnerAskDrawerKeys {
        OwnerAskDrawerKeys(
            vm: vm, ask: ask, editable: editable,
            cursor: Binding(get: { box.cursor }, set: { box.cursor = $0 }),
            fieldFocus: Binding(get: { box.field }, set: { box.field = $0 }),
            commentStep: Binding(get: { box.comment }, set: { box.comment = $0 })
        )
    }

    private func activeDrawer(_ vm: WorkbenchesViewModel) -> WorkbenchesViewModel {
        vm.asks.setDrawerKeysActive(true, projectID: project)
        return vm
    }

    func testDrawerDigitsPickAtTheCursorAndTabMovesIt() async throws {
        let id = try await insert("question", payload: Self.twoQuestions)
        let vm = activeDrawer(try makeVM())
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let keys = drawerKeys(vm, ask, box)

        XCTAssertTrue(keys.press(digit("2")), "no cursor yet: the first question")
        XCTAssertEqual(box.cursor, 0)
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).picks["a"]?.labels, ["No"])
        XCTAssertFalse(keys.press(digit("3")), "the first question has two options")

        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .tab)))
        XCTAssertEqual(keys.shownStop, .question("b"))
        XCTAssertTrue(keys.press(digit("3")))
        XCTAssertTrue(keys.press(digit("1")))
        XCTAssertTrue(keys.press(digit("3")), "a multi-choice option toggles")
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).picks["b"]?.labels, ["X"])

        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .tab)))
        XCTAssertEqual(keys.shownStop, .note)
        XCTAssertFalse(keys.press(digit("1")), "the note takes no digit")
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(box.field?.stop, .note, "Return writes in the note")
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .tab, shift: true)))
        XCTAssertEqual(keys.shownStop, .question("b"))
        XCTAssertFalse(keys.press(digit("n")), "N / P are a review's")
    }

    /// K7: an inactive drawer (not clicked, or clicked away from) leaves
    /// Tab to the window's key-view loop and every other key alone.
    func testAnInactiveDrawerTakesNoKey() async throws {
        let id = try await insert("question", payload: Self.twoQuestions)
        let vm = try makeVM()
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let keys = drawerKeys(vm, ask, box)

        for press in [OwnerAskKeyMap.Press(key: .tab), OwnerAskKeyMap.Press(key: .returnKey), digit("1"), digit("j"), digit("k")] {
            XCTAssertFalse(keys.press(press), "\(press.key)")
        }
        XCTAssertNil(box.cursor)
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).picks, [:])

        vm.asks.setDrawerKeysActive(true, projectID: project)
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .tab)), "a click in the drawer made it active")
        vm.asks.setDrawerKeysActive(false, projectID: project)
        XCTAssertFalse(keys.press(OwnerAskKeyMap.Press(key: .tab)), "a click elsewhere ended it")

        vm.asks.setDrawerKeysActive(true, projectID: project)
        vm.asks.openDrawer(ask)
        vm.asks.closeDrawer(projectID: project)
        XCTAssertFalse(vm.asks.drawerKeysActive.contains(project), "the drawer going ends it")
    }

    func testDrawerDigitsMarkAStepAndOnlyABrokenStepHasAField() async throws {
        let id = try await insert("check", payload: Self.checklist)
        let vm = activeDrawer(try makeVM())
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let keys = drawerKeys(vm, ask, box)

        XCTAssertFalse(keys.press(OwnerAskKeyMap.Press(key: .returnKey)), "an unmarked step has no field")
        XCTAssertNil(box.field)
        XCTAssertTrue(keys.press(digit("1")))
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).checks["1"], .ok)
        XCTAssertTrue(keys.press(digit("1")))
        XCTAssertNil(vm.asks.drafts.askDraft(for: id).checks["1"], "the same mark again clears it, as a second click does")
        XCTAssertTrue(keys.press(digit("2")))
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).checks["1"], .broken)
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(box.field?.stop, .step("1"), "What happened? takes the keyboard")
        XCTAssertFalse(keys.press(digit("4")), "three marks")
    }

    /// K9: N / P need a comment whose passage is in the rendered snapshot.
    func testCommentKeysNeedAPlacedComment() async throws {
        let id = try await insert("review", payload: "{}")
        try await pool.write { db in
            try db.execute(sql: "UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?", arguments: ["# Plan\n\nThe plan is here.\n", id])
        }
        let vm = activeDrawer(try makeVM())
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let keys = drawerKeys(vm, ask, box)

        XCTAssertFalse(keys.press(digit("n")), "no comment to go to")
        let missing = CommentAnchor(quote: "nowhere in it", prefix: "", suffix: "", heading: "")
        vm.asks.editDraft(id) { $0.comments.append(OwnerAskCommentDraft(anchor: missing, body: "Why?")) }
        XCTAssertFalse(keys.press(digit("n")), "a comment not placed (the snapshot not rendered yet)")
        await vm.asks.reviewDocuments.renderSnapshot(ask)
        XCTAssertFalse(keys.press(digit("n")), "a comment whose passage is not in the snapshot")
        XCTAssertNil(box.comment)

        let placed = CommentAnchor(quote: "plan is", prefix: "", suffix: "", heading: "")
        vm.asks.editDraft(id) { $0.comments.append(OwnerAskCommentDraft(anchor: placed, body: "Good")) }
        XCTAssertTrue(keys.press(digit("n")))
        XCTAssertEqual(box.comment?.forward, true)
        XCTAssertTrue(keys.press(digit("p")))
        XCTAssertEqual(box.comment?.forward, false)
    }

    func testNoDrawerKeyOnAnAskBeingAnswered() async throws {
        let id = try await insert("question", payload: Self.twoQuestions)
        let vm = activeDrawer(try makeVM())
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let closed = drawerKeys(vm, ask, box, editable: false)

        XCTAssertFalse(closed.press(digit("1")))
        XCTAssertFalse(closed.press(OwnerAskKeyMap.Press(key: .tab)))
        XCTAssertFalse(closed.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).picks, [:])
    }

    // MARK: - The catcher

    /// A view that takes the keyboard and types nothing: a terminal's stand-in.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeWindow(views: [NSView]) -> NSWindow {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        views.forEach(content.addSubview)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    /// The ANSI key code a test event carries for the characters it types.
    private static let keyCodes: [String: UInt16] = [
        "a": 0x00, "j": 0x26, "k": 0x28, "x": 0x07, "1": 0x12, "\t": 0x30, "\r": CommentEditorKeys.returnKeyCode
    ]

    private func event(
        _ window: NSWindow,
        _ characters: String,
        _ flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode ?? Self.keyCodes[characters] ?? 0x32))
    }

    private func commandReturn(_ window: NSWindow) throws -> NSEvent {
        try event(window, "\r", .command)
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    /// ⌘↩ / ⌘⇧↩ still press the answer buttons (owner ask #90) beside the
    /// new bare keys, and neither is taken while a field has the keyboard.
    func testCommandReturnStillAnswers() throws {
        var answerKeys: [Bool] = []
        var presses: [OwnerAskKeyMap.Press] = []
        let root = VStack {
            CommentTextEditor(text: .constant(""))
        }
        .frame(width: 200, height: 100)
        .background(OwnerAskKeyCatcher { answerKeys.append($0) } onPress: { press in
            presses.append(press)
            return press.key == .character("j")
        })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let field = try XCTUnwrap(textViews(in: host).first)

        window.makeFirstResponder(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: try commandReturn(window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "\r", [.command, .shift])))
        XCTAssertEqual(answerKeys, [false, true])
        XCTAssertEqual(presses, [], "⌘↩ never reaches the bare keys")
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "j")))
        XCTAssertFalse(window.performKeyEquivalent(with: try event(window, "x")), "a key nothing acts on goes on")
        XCTAssertEqual(presses.map(\.key), [.character("j"), .character("x")])

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(window.performKeyEquivalent(with: try event(window, "j")), "a field keeps its typing")
        XCTAssertEqual(presses.count, 2)
        XCTAssertEqual(answerKeys, [false, true])
    }

    /// K5: the real gate — with a terminal-like view or a web view (Monaco)
    /// holding the keyboard, neither the page's nor the drawer's catcher
    /// takes a bare key or even sees it.
    func testNoCatcherTakesAKeyFromTheTerminalOrMonaco() throws {
        var pagePresses = 0
        var drawerPresses = 0
        let page = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 0, y: 80, width: 200, height: 20))
        page.onPress = { _ in
            pagePresses += 1
            return true
        }
        let drawer = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 100, y: 0, width: 100, height: 80))
        drawer.onKey = { _ in drawerPresses += 1 }
        drawer.onPress = { _ in
            drawerPresses += 1
            return true
        }
        let terminal = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        let monaco = WKWebView(frame: NSRect(x: 0, y: 40, width: 100, height: 40), configuration: WKWebViewConfiguration())
        let window = makeWindow(views: [page, drawer, terminal, monaco])
        defer { window.close() }

        let keys = ["a", "j", "1", "\t", "\r"]
        XCTAssertTrue(window.makeFirstResponder(terminal))
        for characters in keys {
            XCTAssertFalse(window.performKeyEquivalent(with: try event(window, characters)), "\(characters) stays the terminal's")
        }
        XCTAssertTrue(window.makeFirstResponder(monaco))
        for characters in keys {
            // Whatever the web view itself does with it: no catcher sees it.
            _ = window.performKeyEquivalent(with: try event(window, characters))
        }
        XCTAssertEqual(pagePresses, 0)
        XCTAssertEqual(drawerPresses, 0)

        window.makeFirstResponder(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "a")), "with nothing focused they do")
        XCTAssertEqual(pagePresses + drawerPresses, 1)
    }

    /// K6: letters by their key — the owner's Russian layout types "о" on J.
    func testALetterIsReadByItsKeyOnARussianLayout() throws {
        var presses: [OwnerAskKeyMap.Press] = []
        let catcher = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        catcher.onPress = { press in
            presses.append(press)
            return true
        }
        let window = makeWindow(views: [catcher])
        defer { window.close() }

        window.makeFirstResponder(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "о", keyCode: 0x26)))
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "ф", keyCode: 0x00)))
        XCTAssertEqual(presses.map(\.key), [.character("j"), .character("a")])
        XCTAssertEqual(OwnerAskKeyMap.action(for: presses[0], at: .drawer(choices: 0, isReview: false)), .nextAsk)
        XCTAssertEqual(OwnerAskKeyMap.action(for: presses[1], at: .page), .openStack)
    }

    /// K8: a window that is not key (a panel such as Open Quickly is) or
    /// has a sheet up takes nothing.
    func testACatcherOutsideTheKeyWindowTakesNothing() throws {
        var answerKeys = 0
        var presses = 0
        let catcher = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        catcher.onKey = { _ in answerKeys += 1 }
        catcher.onPress = { _ in
            presses += 1
            return true
        }
        let window = makeWindow(views: [catcher])
        defer { window.close() }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        window.makeFirstResponder(nil)

        catcher.keyWindow = { panel }
        XCTAssertFalse(window.performKeyEquivalent(with: try event(window, "j")))
        XCTAssertFalse(window.performKeyEquivalent(with: try commandReturn(window)))
        XCTAssertEqual(answerKeys + presses, 0)

        catcher.keyWindow = { window }
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "j")))
        XCTAssertEqual(presses, 1, "its own window key: taken")
    }

    /// K7: where a click falls decides the drawer's active state.
    func testAClickIsInsideOnlyOnTheCatchersFrame() {
        let catcher = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 100, y: 0, width: 100, height: 80))
        let window = makeWindow(views: [catcher])
        defer { window.close() }

        XCTAssertTrue(catcher.isInside(NSPoint(x: 150, y: 40)))
        XCTAssertFalse(catcher.isInside(NSPoint(x: 50, y: 40)), "the terminal beside it")
    }

    /// A catcher behind the page has no `onKey`: ⌘↩ passes on.
    func testAPageCatcherLeavesCommandReturn() throws {
        var presses = 0
        let catcher = OwnerAskKeyCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        catcher.onPress = { _ in
            presses += 1
            return false
        }
        let window = makeWindow(views: [catcher])
        defer { window.close() }

        window.makeFirstResponder(nil)
        XCTAssertFalse(window.performKeyEquivalent(with: try commandReturn(window)))
        XCTAssertEqual(presses, 1, "offered as a press, which takes nothing with ⌘")
    }
}
