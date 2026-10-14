import AppKit
import SwiftUI
import WatchtowerCore

/// The sessions panel's keyboard (board #480, spec
/// 2026-10-12-sessions-panel-design §4.4). Laid behind the panel's list,
/// it accepts first responder, and the panel **has the keyboard** exactly
/// while it is first responder: it takes it on a click on the list's empty
/// space (a click inside its frame that hits no list row,
/// `clickTakesPanelKeyboard`), and when `keyboardRequest`
/// changes (the SESSIONS label, the group header, a ✕, the toast's Undo).
/// It loses it the normal AppKit way — a click into the terminal, Monaco,
/// a field. A row click keeps sending the keyboard into the session's
/// terminal (owner decision, ask #195).
///
/// While it holds the keyboard: ↑ ↓ Return Esc as keys, ⌘⌫ and ⌘Z as key
/// equivalents — taken only then, so outside it they belong to whoever has
/// the keyboard (Claude Code's line editing, Monaco's undo). Like
/// `OwnerAskKeyCatcher`, only in the key window with no sheet up.
struct SessionsPanelKeyView: NSViewRepresentable {
    enum Command: Equatable {
        case cursorUp
        case cursorDown
        case openCursor
        case handBack
        case deleteCursor
        case undoDelete
    }

    /// Changing it hands the keyboard to the panel.
    let keyboardRequest: Int
    /// A command while the panel has the keyboard; true when it acted.
    let onCommand: (Command) -> Bool
    /// The panel took (true) or lost (false) the keyboard.
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handledRequest = keyboardRequest
        bindCallbacks(view)
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        bindCallbacks(view)
        view.applyKeyboardRequest(keyboardRequest)
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stopWatchingPanelClicks()
    }

    private func bindCallbacks(_ view: KeyView) {
        view.onCommand = onCommand
        view.onFocusChange = onFocusChange
    }

    /// The bare key `event` is while the panel has the keyboard; nil for
    /// any other key or with ⌘ ⌥ ⌃.
    static func panelKeyCommand(_ event: NSEvent) -> Command? {
        guard event.type == .keyDown,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        switch event.keyCode {
        case 126: return .cursorUp
        case 125: return .cursorDown
        case CommentEditorKeys.returnKeyCode, CommentEditorKeys.keypadEnterKeyCode: return event.isARepeat ? nil : .openCursor
        case 53: return .handBack
        default: return nil
        }
    }

    /// ⌘⌫ or ⌘Z (Z by its character, or by its key on a non-Latin
    /// layout); nil for anything else. A held ⌘⌫ deletes one row only:
    /// its auto-repeats are not taken.
    static func panelEquivalentCommand(_ event: NSEvent) -> Command? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command] else { return nil }
        if event.keyCode == 51 { return event.isARepeat ? nil : .deleteCursor }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let latin = characters.unicodeScalars.allSatisfy(\.isASCII)
        if characters == "z" || (!latin && event.keyCode == 6) { return .undoDelete }
        return nil
    }

    final class KeyView: NSView {
        var onCommand: ((Command) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?
        /// The last `keyboardRequest` acted on.
        var handledRequest = 0
        /// As `OwnerAskKeyCatcher.CatcherView.isKey`; a seam for tests.
        var isKey: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow || !$0.isVisible }
        /// Whether a sheet is up; a seam for tests.
        var hasSheet: @MainActor (NSWindow) -> Bool = { $0.attachedSheet != nil }
        private var clickMonitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override var focusRingType: NSFocusRingType {
            get { .none }
            set {}
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange?(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onFocusChange?(false) }
            return resigned
        }

        /// Whether the panel has the keyboard: first responder of the key
        /// window, no sheet up.
        func holdsPanelKeyboard() -> Bool {
            guard let window, window.firstResponder === self else { return false }
            return isKey(window) && !hasSheet(window)
        }

        func takePanelKeyboard() {
            guard let window, window.firstResponder !== self, !hasSheet(window) else { return }
            window.makeFirstResponder(self)
        }

        /// The keyboard request `request` (a new serial from the view
        /// model) is taken once, after the update that carried it.
        func applyKeyboardRequest(_ request: Int) {
            guard handledRequest != request else { return }
            handledRequest = request
            DispatchQueue.main.async { [weak self] in self?.takePanelKeyboard() }
        }

        override func keyDown(with event: NSEvent) {
            guard holdsPanelKeyboard() else {
                super.keyDown(with: event)
                return
            }
            guard let command = SessionsPanelKeyView.panelKeyCommand(event) else {
                passUnhandledPanelKey(event)
                return
            }
            // Esc with no running terminal on screen: the keyboard just goes.
            if onCommand?(command) != true, command == .handBack { window?.makeFirstResponder(nil) }
        }

        /// A key the panel has no use for while it has the keyboard: Tab
        /// and ⇧Tab move it on like from any key view; anything else is
        /// dropped without the system beep.
        private func passUnhandledPanelKey(_ event: NSEvent) {
            guard event.keyCode == 48 else { return }
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard holdsPanelKeyboard(), let command = SessionsPanelKeyView.panelEquivalentCommand(event),
                  onCommand?(command) == true else { return super.performKeyEquivalent(with: event) }
            return true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watchPanelClicks()
        }

        /// Whether the local click monitor is installed; a seam for tests.
        var isWatchingPanelClicks: Bool { clickMonitor != nil }

        /// A local monitor while it is in a window; gone once it leaves.
        private func watchPanelClicks() {
            guard window != nil else {
                stopWatchingPanelClicks()
                return
            }
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.clickTakesPanelKeyboard(event) else { return }
                    // Once the click is handled: the list would otherwise keep it.
                    DispatchQueue.main.async { [weak self] in self?.takePanelKeyboard() }
                }
                return event
            }
        }

        /// A click in this window, inside this view's frame (the list's),
        /// that hits no list row: the list's empty space. A row (a session,
        /// the group header) is decided by what the click hits, not by the
        /// hover state, which lags behind a click that just scrolled.
        func clickTakesPanelKeyboard(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  convert(bounds, to: nil).contains(event.locationInWindow) else { return false }
            return !Self.isInsideListRow(window.contentView?.hitTest(event.locationInWindow))
        }

        /// `view` is a list row or inside one (SwiftUI's List draws its rows
        /// as table row views).
        static func isInsideListRow(_ view: NSView?) -> Bool {
            var current = view
            while let candidate = current {
                if candidate is NSTableRowView { return true }
                current = candidate.superview
            }
            return false
        }

        func stopWatchingPanelClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }
}

extension View {
    /// The sessions panel's keyboard behind its list (`SessionsPanelKeyView`)
    /// wired to the view model's cursor, delete and Undo.
    func sessionsPanelKeys(
        vm: WorkbenchesViewModel,
        projectID: Int64,
        actions: SessionRowActions,
        hasKeyboard: Binding<Bool>
    ) -> some View {
        background(SessionsPanelKeyView(
            keyboardRequest: vm.panelKeyboardSerial,
            onCommand: { SessionsPanelKeyCommands(vm: vm, projectID: projectID, actions: actions).performPanelKey($0) },
            onFocusChange: { has in
                hasKeyboard.wrappedValue = has
                if has { vm.enterPanelKeyboard(projectID: projectID) }
            }
        ))
    }
}

/// What each panel key does (spec 2026-10-12-sessions-panel-design §4.4).
@MainActor
struct SessionsPanelKeyCommands {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let actions: SessionRowActions

    /// True when the key was taken. ⌘Z passes on with nothing to undo.
    func performPanelKey(_ command: SessionsPanelKeyView.Command) -> Bool {
        switch command {
        case .cursorUp:
            vm.movePanelCursor(-1, projectID: projectID)
        case .cursorDown:
            vm.movePanelCursor(1, projectID: projectID)
        case .openCursor:
            Task { await vm.openAtPanelCursor(projectID: projectID) }
        case .handBack:
            return vm.returnKeyboardToTerminal(projectID: projectID)
        case .deleteCursor:
            Task {
                if case let .confirm(session)? = await vm.deleteAtPanelCursor(projectID: projectID) {
                    actions.delete(session)
                }
            }
        case .undoDelete:
            guard vm.pendingDeleteToast != nil else { return false }
            Task { await vm.undoPendingDeletes() }
        }
        return true
    }
}
