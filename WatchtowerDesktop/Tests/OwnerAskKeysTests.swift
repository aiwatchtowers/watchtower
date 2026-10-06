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
        XCTAssertEqual(itemNote.placeholder, "What broke? (required)")
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

    private func key(_ window: NSWindow, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                       keyCode: CommentEditorKeys.returnKeyCode))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    /// A field beside the drawer (a target comment), and in the drawer a
    /// field of its own and read-only text (a review's document).
    func testTheCatcherTakesTheKeysOnlyWhileNoFieldHasTheKeyboard() throws {
        var keys: [Bool] = []
        var outsideSent = 0
        var insideSent = 0
        // Labelled: a trailing closure would be `onFocus`.
        // swiftlint:disable trailing_closure
        let root = HStack(spacing: 0) {
            CommentTextEditor(text: .constant(""), onSubmit: { outsideSent += 1 })
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
        let document = try XCTUnwrap(views.first { !$0.isEditable })

        window.makeFirstResponder(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, [.command, .shift])))
        XCTAssertFalse(window.performKeyEquivalent(with: try key(window, [.command, .option])), "⌘⌥↩ is the code question's")
        XCTAssertEqual(keys, [false, true])

        XCTAssertTrue(window.makeFirstResponder(document))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertEqual(keys, [false, true, false], "the drawer's own read-only text")

        XCTAssertTrue(window.makeFirstResponder(inside))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertTrue(window.makeFirstResponder(outside))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window, .command)))
        XCTAssertEqual(keys, [false, true, false], "a focused field keeps its ⌘↩")
        XCTAssertEqual(insideSent, 1)
        XCTAssertEqual(outsideSent, 1)
    }
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
