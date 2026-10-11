import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Owner asks without the mouse (board #412): the bare keys of the page,
/// the drawer and a Quick ask's banner or card, and ⌘↩ / ⌘⇧↩ unchanged.
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

    private func insert(_ kind: String, payload: String, level: String = "full") async throws -> Int64 {
        let project = project
        return try await pool.write { db in
            let id = try TestDatabase.insertOwnerAsk(db, projectID: project, kind: kind, payload: payload,
                                                     docPath: kind == "review" ? "docs/plan.md" : "")
            try db.execute(sql: "UPDATE owner_asks SET level = ? WHERE id = ?", arguments: [level, id])
            return id
        }
    }

    private func makeVM() throws -> WorkbenchesViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskKeyNavigationTests-\(UUID().uuidString)"))
        return WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
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
        var opened = 0

        let elsewhere = OwnerAskCardKeys(vm: vm, ask: ask, focused: false) { opened += 1 }
        XCTAssertFalse(elsewhere.press(digit("1")), "a digit typed in the terminal is the terminal's")
        XCTAssertFalse(elsewhere.press(OwnerAskKeyMap.Press(key: .returnKey)))
        let banner = OwnerAskCardKeys(vm: vm, ask: ask, focused: true) { opened += 1 }
        XCTAssertFalse(banner.press(digit("3")), "two options: 3 picks nothing")
        let open = try await stored(keyed)
        XCTAssertEqual(open?.isOpen, true, "nothing answered yet")
        XCTAssertEqual(opened, 0)

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
        var opened = 0
        var moves: [Bool] = []
        let card = OwnerAskCardKeys(vm: vm, ask: ask, focused: true, open: { opened += 1 }, move: { moves.append($0); return true })

        XCTAssertFalse(card.press(digit("1")), "a Full ask has no one-tap row")
        XCTAssertTrue(card.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertTrue(card.press(digit("j")))
        XCTAssertTrue(card.press(OwnerAskKeyMap.Press(key: .upArrow)))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(moves, [true, false])
        let stillOpen = try await stored(id)
        XCTAssertEqual(stillOpen?.isOpen, true)
    }

    func testAChoiceNamesItsKey() {
        XCTAssertEqual(OwnerAskCardKeys.hint("Remove the flag", index: 0), "Remove the flag (press 1)")
        XCTAssertEqual(OwnerAskCardKeys.hint("Later", index: 3), "Later", "1–3 only")
    }

    // MARK: - The page

    func testAOpensTheStackOnlyWithAnAskWaiting() async throws {
        let vm = try makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = project
        vm.panelVisible = false
        await vm.asks.load(projectID: project)
        XCTAssertFalse(vm.openStackFromKeyboard(), "no ask waits: A is left alone")
        XCTAssertFalse(vm.asks.stackKeyboardRequested)

        _ = try await insert("question", payload: Self.quick)
        await vm.asks.load(projectID: project)
        XCTAssertTrue(vm.openStackFromKeyboard())
        XCTAssertTrue(vm.panelVisible, "the panel comes back to show the stack")
        XCTAssertTrue(vm.asks.stackKeyboardRequested)
    }

    // MARK: - The drawer

    private final class CursorBox {
        var cursor: Int?
        var field: OwnerAskFieldFocus?
        var comment: OwnerAskCommentStep?
    }

    private func drawerKeys(_ vm: WorkbenchesViewModel, _ ask: OwnerAsk, _ box: CursorBox) -> OwnerAskDrawerKeys {
        OwnerAskDrawerKeys(
            vm: vm, ask: ask, editable: ask.isOpen && !vm.asks.isAnswering(ask.id),
            cursor: Binding(get: { box.cursor }, set: { box.cursor = $0 }),
            fieldFocus: Binding(get: { box.field }, set: { box.field = $0 }),
            commentStep: Binding(get: { box.comment }, set: { box.comment = $0 })
        )
    }

    func testDrawerDigitsPickAtTheCursorAndTabMovesIt() async throws {
        let id = try await insert("question", payload: Self.twoQuestions)
        let vm = try makeVM()
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

    func testDrawerDigitsMarkAStepAndOnlyABrokenStepHasAField() async throws {
        let id = try await insert("check", payload: Self.checklist)
        let vm = try makeVM()
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

    func testCommentKeysNeedAComment() async throws {
        let id = try await insert("review", payload: "{}")
        let vm = try makeVM()
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let keys = drawerKeys(vm, ask, box)

        XCTAssertFalse(keys.press(digit("n")), "no comment to go to")
        let anchor = CommentAnchor(quote: "plan", prefix: "", suffix: "", heading: "")
        vm.asks.editDraft(id) { $0.comments.append(OwnerAskCommentDraft(anchor: anchor, body: "Why?")) }
        XCTAssertTrue(keys.press(digit("n")))
        XCTAssertEqual(box.comment?.forward, true)
        XCTAssertTrue(keys.press(digit("p")))
        XCTAssertEqual(box.comment?.forward, false)
    }

    func testNoDrawerKeyOnAnAskBeingAnswered() async throws {
        let id = try await insert("question", payload: Self.twoQuestions)
        let vm = try makeVM()
        let ask = try await loaded(vm, id)
        let box = CursorBox()
        let closed = OwnerAskDrawerKeys(
            vm: vm, ask: ask, editable: false,
            cursor: Binding(get: { box.cursor }, set: { box.cursor = $0 }),
            fieldFocus: Binding(get: { box.field }, set: { box.field = $0 }),
            commentStep: Binding(get: { box.comment }, set: { box.comment = $0 })
        )
        XCTAssertFalse(closed.press(digit("1")))
        XCTAssertFalse(closed.press(OwnerAskKeyMap.Press(key: .tab)))
        XCTAssertFalse(closed.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(vm.asks.drafts.askDraft(for: id).picks, [:])
    }

    // MARK: - The catcher

    private func event(
        _ window: NSWindow,
        _ characters: String,
        _ flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
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
        let returnKey = CommentEditorKeys.returnKeyCode

        window.makeFirstResponder(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "\r", .command, keyCode: returnKey)))
        XCTAssertTrue(window.performKeyEquivalent(with: try event(window, "\r", [.command, .shift], keyCode: returnKey)))
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

    /// A catcher behind the page has no `onKey`: ⌘↩ passes on.
    func testAPageCatcherLeavesCommandReturn() throws {
        var presses = 0
        // Labelled: a trailing closure would be `onKey`.
        // swiftlint:disable:next trailing_closure
        let catcher = OwnerAskKeyCatcher(onPress: { _ in
            presses += 1
            return false
        })
        let host = NSHostingView(rootView: Color.clear.frame(width: 200, height: 100).background(catcher))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        window.makeFirstResponder(nil)
        XCTAssertFalse(window.performKeyEquivalent(with: try event(window, "\r", .command, keyCode: CommentEditorKeys.returnKeyCode)))
        XCTAssertEqual(presses, 1, "offered as a press, which takes nothing with ⌘")
    }
}
