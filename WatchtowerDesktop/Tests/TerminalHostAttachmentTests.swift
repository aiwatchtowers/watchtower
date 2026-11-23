import AppKit
import WebKit
import XCTest
@testable import WatchtowerDesktop

/// The terminal host is reused when the page switches projects: after
/// A → B → A the container must show A's terminal alone, not B's on top.
@MainActor
final class TerminalHostAttachmentTests: XCTestCase {
    private let margin = TerminalHostAttachment.margin

    func testSwitchingBackShowsTheSelectedProjectsTerminalAlone() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminalA = NSView()
        let terminalB = NSView()

        XCTAssertTrue(TerminalHostAttachment.attach(terminalA, to: container))
        XCTAssertTrue(TerminalHostAttachment.attach(terminalB, to: container))
        XCTAssertEqual(container.subviews, [terminalB])

        XCTAssertTrue(TerminalHostAttachment.attach(terminalA, to: container), "switching back re-attaches")
        XCTAssertEqual(container.subviews, [terminalA])
        XCTAssertEqual(terminalA.frame, container.bounds.insetBy(dx: margin, dy: margin), "inset by the margin")
        XCTAssertNil(terminalB.superview)
    }

    func testReattachingTheShownTerminalIsANoOp() {
        let container = NSView()
        let terminal = NSView()
        TerminalHostAttachment.attach(terminal, to: container)
        XCTAssertFalse(TerminalHostAttachment.attach(terminal, to: container))
        XCTAssertEqual(container.subviews, [terminal])
    }

    /// A container left holding a stale second view (the pre-fix state)
    /// is cleaned up even when the wanted terminal is already inside it.
    func testStaleSiblingIsRemovedWhenTheTerminalIsAlreadyInside() {
        let container = NSView()
        let terminal = NSView()
        let stale = NSView()
        container.addSubview(terminal)
        container.addSubview(stale)
        XCTAssertTrue(TerminalHostAttachment.attach(terminal, to: container))
        XCTAssertEqual(container.subviews, [terminal])
    }

    /// The margin holds on every resize, so SwiftTerm's cols/rows always
    /// come from the inset size (the last column is never under the edge).
    func testContainerKeepsTheTerminalInsetAcrossResizes() {
        let container = TerminalContainerView(frame: .zero)
        let terminal = NSView()
        TerminalHostAttachment.attach(terminal, to: container)
        XCTAssertEqual(terminal.frame.size, .zero, "a zero-size container never yields a negative frame")

        container.setFrameSize(NSSize(width: 600, height: 400))
        XCTAssertEqual(terminal.frame, container.bounds.insetBy(dx: margin, dy: margin))
        container.setFrameSize(NSSize(width: 300, height: 200))
        XCTAssertEqual(terminal.frame, container.bounds.insetBy(dx: margin, dy: margin))
    }

    /// The margin is the terminal's own background, following it when the
    /// terminal repaints its layer (OSC 11, reverse video) and cleared when
    /// no terminal is shown.
    func testContainerMirrorsTheTerminalLayerBackground() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = NSView()
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = NSColor.black.cgColor
        TerminalHostAttachment.attach(terminal, to: container)
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.black.cgColor)

        terminal.layer?.backgroundColor = NSColor.white.cgColor
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.white.cgColor, "a repainted terminal recolours the margin")

        let other = NSView()
        other.wantsLayer = true
        other.layer?.backgroundColor = NSColor.red.cgColor
        TerminalHostAttachment.attach(other, to: container)
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.red.cgColor, "switching follows the shown terminal")
        terminal.layer?.backgroundColor = NSColor.blue.cgColor
        XCTAssertEqual(container.layer?.backgroundColor, NSColor.red.cgColor, "the detached terminal no longer drives it")

        other.removeFromSuperview()
        XCTAssertNil(container.layer?.backgroundColor)
    }

    /// An attach that changed something focuses (as before); an attached
    /// terminal focuses only for a request it has not honoured yet.
    func testTheHostFocusesAfterAnAttachOrForANewRequest() {
        XCTAssertTrue(TerminalHostAttachment.needsFocus(attached: true, requested: nil, honoured: nil))
        XCTAssertFalse(TerminalHostAttachment.needsFocus(attached: false, requested: nil, honoured: nil))
        XCTAssertTrue(TerminalHostAttachment.needsFocus(attached: false, requested: 3, honoured: nil))
        XCTAssertTrue(TerminalHostAttachment.needsFocus(attached: false, requested: 3, honoured: 2))
        XCTAssertFalse(TerminalHostAttachment.needsFocus(attached: false, requested: 3, honoured: 3), "honoured once")
        XCTAssertFalse(TerminalHostAttachment.needsFocus(attached: true, requested: nil, honoured: nil, obscured: true),
                       "a fresh attach under an expanded ask drawer takes no focus")
        XCTAssertFalse(TerminalHostAttachment.needsFocus(attached: false, requested: 4, honoured: 3, obscured: true),
                       "nor does a request")
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        return window
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// A new host SwiftUI puts in the window only after the focus turn
    /// (seen switching workbenches from the switcher popover, #1150): the
    /// keyboard follows once the container is in a window — unless
    /// something there has it by then. In a window already, it moves on
    /// the next turn.
    func testFocusWaitsForTheContainersWindow() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)

        container.focusTerminal(terminal)
        drainMainQueue()
        content.addSubview(container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "focused once in the window")

        container.removeFromSuperview()
        XCTAssertTrue(host.makeFirstResponder(nil))
        container.focusTerminal(terminal)
        drainMainQueue()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        content.addSubview(field)
        XCTAssertTrue(host.makeFirstResponder(field))
        content.addSubview(container)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "the keyboard the owner put elsewhere stays there")

        container.removeFromSuperview()
        content.addSubview(container)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "a wait is used once")

        container.focusTerminal(terminal)
        XCTAssertFalse(host.firstResponder === terminal, "not inside the update")
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "in a window: the next turn")
    }

    /// The deferred focus yields only to typed input (a text view or field
    /// editor, a web editor, another terminal). The sessions list and the
    /// panel's key view, where a row click can leave the keyboard, keep it
    /// from no terminal that arrives (#1150).
    func testDeferredFocusOverridesTheListAndThePanel() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let list = ListLike(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let panel = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 50, width: 50, height: 50))
        content.addSubview(list)
        content.addSubview(panel)
        for holder in [list, panel] as [NSView] {
            let container = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
            let terminal = FocusableView()
            TerminalHostAttachment.attach(terminal, to: container)
            container.focusTerminal(terminal)
            drainMainQueue()
            XCTAssertTrue(host.makeFirstResponder(holder))
            content.addSubview(container)
            drainMainQueue()
            XCTAssertTrue(host.firstResponder === terminal, "\(type(of: holder)) keeps the keyboard from the terminal")
            container.removeFromSuperview()
        }

        let inTerminal = NSView()
        TerminalContainerView().addSubview(inTerminal)
        XCTAssertTrue(TerminalContainerView.holdsTypedInput(NSTextView()), "a text view or field editor")
        XCTAssertTrue(TerminalContainerView.holdsTypedInput(inTerminal), "another terminal")
        let webEditor = WKWebView()
        let insideWeb = NSView()
        webEditor.addSubview(insideWeb)
        XCTAssertTrue(TerminalContainerView.holdsTypedInput(insideWeb), "a web editor (Monaco)")
        XCTAssertFalse(TerminalContainerView.holdsTypedInput(host))
        XCTAssertFalse(TerminalContainerView.holdsTypedInput(nil))
    }

    /// The panel taking the keyboard on the owner's request (the SESSIONS
    /// label, the group header, a ✕, Undo, its empty space) after a
    /// terminal's focus was asked wins over that focus still pending — the
    /// later choice (ask #195). A panel that only holds the keyboard from
    /// before is still overridden (`testDeferredFocusOverridesTheListAndThePanel`).
    func testALaterPanelKeyboardRequestWinsOverAPendingFocus() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let panel = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        content.addSubview(panel)

        let waiting = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: waiting)
        waiting.focusTerminal(terminal)
        drainMainQueue()
        panel.takePanelKeyboard()
        XCTAssertTrue(host.firstResponder === panel)
        content.addSubview(waiting)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === panel, "waiting for the window")

        waiting.focusTerminal(terminal)
        XCTAssertTrue(host.makeFirstResponder(nil))
        panel.takePanelKeyboard()
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === panel, "queued for its turn")
    }

    /// A panel claim is its own window's: the panel of another window
    /// taking its keyboard leaves this window's pending focus alone.
    func testAPanelClaimInAnotherWindowLeavesThePendingFocus() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let other = window()
        let otherPanel = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        try XCTUnwrap(other.contentView).addSubview(otherPanel)

        let waiting = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: waiting)
        waiting.focusTerminal(terminal)
        drainMainQueue()
        otherPanel.takePanelKeyboard()
        content.addSubview(waiting)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "waiting for the window")

        XCTAssertTrue(host.makeFirstResponder(nil))
        waiting.focusTerminal(terminal)
        otherPanel.takePanelKeyboard()
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "queued for its turn")
    }

    /// An update that finds the terminal covered (an ask drawer, a page
    /// screen) or kept from the keyboard drops a focus still pending —
    /// waiting for the window or for its turn: dropped, not kept. An
    /// update that only decides no new focus keeps it.
    func testACoveredTerminalDropsItsPendingFocus() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)

        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, keptOff: false)
        drainMainQueue()
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: false, keptOff: false)
        content.addSubview(container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "an update with nothing new keeps the wait")

        container.removeFromSuperview()
        XCTAssertTrue(host.makeFirstResponder(nil))
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, keptOff: false)
        drainMainQueue()
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: false, keptOff: true)
        content.addSubview(container)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "covered while waiting for the window")

        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, keptOff: false)
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: false, keptOff: true)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "covered before its turn")
    }

    /// A focus is the terminal's that asked: SwiftUI reuses a host, and a
    /// terminal swapped in before the turn (or before the window) made no
    /// request — it may be one kept from the keyboard (`keepsKeyboard`, an
    /// ask drawer over it).
    func testAFocusIsTheRequestingTerminals() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.addSubview(container)
        let asking = FocusableView()
        let other = FocusableView()
        XCTAssertTrue(host.makeFirstResponder(nil))

        TerminalHostAttachment.attach(asking, to: container)
        container.focusTerminal(asking)
        TerminalHostAttachment.attach(other, to: container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === host, "swapped in before the turn: nobody focused")

        container.removeFromSuperview()
        TerminalHostAttachment.attach(asking, to: container)
        container.focusTerminal(asking)
        drainMainQueue()
        TerminalHostAttachment.attach(other, to: container)
        content.addSubview(container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === host, "swapped in before the window: nobody focused")

        container.removeFromSuperview()
        TerminalHostAttachment.attach(asking, to: container)
        container.focusTerminal(asking)
        drainMainQueue()
        TerminalHostAttachment.attach(other, to: container)
        TerminalHostAttachment.attach(asking, to: container)
        content.addSubview(container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === host, "a swap drops the wait, also swapped back")
    }

    /// The focus queued on entering the window is dropped by an update
    /// that finds the terminal covered before that turn.
    func testACoverBeforeTheWindowTurnDropsTheFocus() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)
        container.focusTerminal(terminal)
        drainMainQueue()

        content.addSubview(container)
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: false, keptOff: true)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal)
    }

    /// The panel's claim counts also when it holds the keyboard already
    /// (the owner clicked the SESSIONS label while it had it).
    func testAClaimByThePanelHoldingTheKeyboardStillCounts() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let panel = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        content.addSubview(panel)
        XCTAssertTrue(host.makeFirstResponder(panel))
        let container = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)
        content.addSubview(container)

        container.focusTerminal(terminal)
        panel.takePanelKeyboard()
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === panel)
    }

    /// Kept off the keyboard: covered, or an attach an ask switched from
    /// the keyboard asked to leave it (`keepsKeyboard`, board #412).
    func testKeptOffTruthTable() {
        for obscured in [false, true] {
            for attached in [false, true] {
                for keeps in [false, true] {
                    XCTAssertEqual(
                        TerminalHostAttachment.keptOff(obscured: obscured, attached: attached, keepsKeyboard: keeps),
                        obscured || (attached && keeps), "obscured=\(obscured) attached=\(attached) keeps=\(keeps)"
                    )
                }
            }
        }
    }

    /// A container that enters the window and leaves it again before the
    /// focus's turn keeps waiting: the next entry gives the focus.
    func testAWaitSurvivesAQuickInAndOut() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)
        container.focusTerminal(terminal)
        drainMainQueue()

        content.addSubview(container)
        container.removeFromSuperview()
        drainMainQueue()
        content.addSubview(container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal)
    }

    /// A row click's request is weighed from the click (`asked`), not from
    /// when it arrives after the open's awaits: the panel taking the
    /// keyboard, or the owner typing in a field, after the click wins — on
    /// a host in the window already and on a fresh one.
    func testARowClicksFocusGivesWayToWhatCameAfterTheClick() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let panel = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        content.addSubview(panel)
        let field = NSTextField(frame: NSRect(x: 0, y: 60, width: 50, height: 22))
        content.addSubview(field)
        let container = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)
        content.addSubview(container)

        var click = TerminalContainerView.keyboardEventCount
        panel.takePanelKeyboard()
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, explicit: true, since: click, keptOff: false)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === panel, "the panel claimed it after the click")

        click = TerminalContainerView.keyboardEventCount
        XCTAssertTrue(host.makeFirstResponder(field))
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, explicit: true, since: click, keptOff: false)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "the owner typed in a field after the click")

        container.removeFromSuperview()
        click = TerminalContainerView.keyboardEventCount
        XCTAssertTrue(host.makeFirstResponder(panel))
        panel.takePanelKeyboard()
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, explicit: true, since: click, keptOff: false)
        drainMainQueue()
        content.addSubview(container)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === panel, "a fresh host too")

        click = TerminalContainerView.keyboardEventCount
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, explicit: true, since: click, keptOff: false)
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "nothing since the click: the terminal takes it")
    }

    /// A host rebuilt later (Workchat → Terminal) reads the center's last
    /// request again with a fresh coordinator: a request its terminal's
    /// host honoured already is no new row click, so the fresh attach
    /// focuses as any attach — not yielding to a panel claim made since
    /// that old click. A request no host of the terminal honoured yet (the
    /// click that opened a fresh host) still counts as the click's.
    func testAnOldRequestIsNoClickForARebuiltHost() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        let panel = SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        content.addSubview(panel)
        let terminal = FocusableView()
        let first = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        content.addSubview(first)

        let click = TerminalContainerView.keyboardEventCount
        TerminalHostAttachment.show(terminal, in: first, focusSerial: 1, focusSince: click, obscured: false) { false }
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal)
        panel.takePanelKeyboard()
        first.subviews.forEach { $0.removeFromSuperview() }
        first.removeFromSuperview()

        let rebuilt = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        content.addSubview(rebuilt)
        TerminalHostAttachment.show(terminal, in: rebuilt, focusSerial: 1, focusSince: click, obscured: false) { false }
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === terminal, "a fresh attach focuses, as before #1150")

        let other = FocusableView()
        let fresh = TerminalContainerView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        content.addSubview(fresh)
        let nextClick = TerminalContainerView.keyboardEventCount
        panel.takePanelKeyboard()
        TerminalHostAttachment.show(other, in: fresh, focusSerial: 2, focusSince: nextClick, obscured: false) { false }
        drainMainQueue()
        XCTAssertTrue(host.firstResponder === panel, "the click's own request: a claim after it wins")
    }

    // MARK: - The focus contract (#1150)

    private enum Holder: CaseIterable {
        case terminal, monaco, list, panel
    }

    /// One case of the contract: a window with the panel's key view (which
    /// numbers the keyboard's moves), another terminal, a web editor, the
    /// list; `holder` has the keyboard; then a row click's request for `T`
    /// — on a host in the window already, or a fresh one that enters it
    /// after — or, `covered`, the host drops it.
    private func focusCase(holder: Holder, fresh: Bool, covered: Bool) throws -> (NSWindow, NSView) {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        content.addSubview(SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        let list = ListLike(frame: NSRect(x: 0, y: 50, width: 50, height: 50))
        content.addSubview(list)
        let otherContainer = TerminalContainerView(frame: NSRect(x: 50, y: 0, width: 100, height: 100))
        let otherTerminal = FocusableView()
        TerminalHostAttachment.attach(otherTerminal, to: otherContainer)
        content.addSubview(otherContainer)
        let monaco = WKWebView(frame: NSRect(x: 150, y: 0, width: 50, height: 50))
        content.addSubview(monaco)
        let panel = try XCTUnwrap(content.subviews.first)
        let holding: NSView = switch holder {
        case .terminal: otherTerminal
        case .monaco: monaco
        case .list: list
        case .panel: panel
        }
        XCTAssertTrue(host.makeFirstResponder(holding))

        let container = TerminalContainerView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)
        if !fresh { content.addSubview(container) }
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: !covered, explicit: !covered, keptOff: covered)
        drainMainQueue()
        if fresh { content.addSubview(container) }
        drainMainQueue()
        return (host, terminal)
    }

    /// A row click's request (row open × host in the window or fresh ×
    /// holder: another terminal, Monaco, the list, the panel × covered):
    /// the terminal takes the keyboard from any holder the owner had before
    /// the click; a covered terminal takes nothing.
    func testTheFocusContractTruthTable() throws {
        for holder in Holder.allCases {
            for fresh in [false, true] {
                for covered in [false, true] {
                    let (host, terminal) = try focusCase(holder: holder, fresh: fresh, covered: covered)
                    let label = "\(holder) fresh=\(fresh) covered=\(covered)"
                    XCTAssertEqual(host.firstResponder === terminal, !covered, label)
                }
            }
        }
    }

    /// The owner typing elsewhere after the request (Monaco, another
    /// terminal) keeps the keyboard there: the fresh host's focus yields.
    /// A focus from an attach alone yields to typed input already there.
    func testAFocusYieldsToTypingThatCameAfterIt() throws {
        let host = window()
        let content = try XCTUnwrap(host.contentView)
        content.addSubview(SessionsPanelKeyView.KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        let monaco = WKWebView(frame: NSRect(x: 50, y: 0, width: 50, height: 50))
        content.addSubview(monaco)
        let container = TerminalContainerView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        let terminal = FocusableView()
        TerminalHostAttachment.attach(terminal, to: container)

        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, explicit: true, keptOff: false)
        drainMainQueue()
        XCTAssertTrue(host.makeFirstResponder(monaco))
        content.addSubview(container)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "the owner moved on after the click")

        container.removeFromSuperview()
        TerminalHostAttachment.settleFocus(terminal, in: container, focus: true, explicit: false, keptOff: false)
        drainMainQueue()
        content.addSubview(container)
        drainMainQueue()
        XCTAssertFalse(host.firstResponder === terminal, "an attach alone yields to Monaco")
    }
}

/// Takes the keyboard like the embedded terminal.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Keeps first responder like SwiftUI's list table (a bare NSTableView
/// outside a scroll view hands it straight to the window).
private final class ListLike: NSTableView {
    override func becomeFirstResponder() -> Bool { true }
}
