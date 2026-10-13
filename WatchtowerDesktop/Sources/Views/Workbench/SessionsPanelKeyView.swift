import AppKit
import SwiftUI
import WatchtowerCore

/// The sessions panel's keyboard (board #480, spec
/// 2026-10-12-sessions-panel-design §4.4). Laid behind the panel's list,
/// it accepts first responder, and the panel **has the keyboard** exactly
/// while it is first responder: it takes it on a click on the list's empty
/// space (`onClick` says whether a click is one), and when `keyboardRequest`
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
    /// A click inside the view's frame; true takes the keyboard (empty
    /// space, not a row).
    let onClick: () -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handledRequest = keyboardRequest
        bindCallbacks(view)
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        bindCallbacks(view)
        guard view.handledRequest != keyboardRequest else { return }
        view.handledRequest = keyboardRequest
        DispatchQueue.main.async { view.takePanelKeyboard() }
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stopWatchingPanelClicks()
    }

    private func bindCallbacks(_ view: KeyView) {
        view.onCommand = onCommand
        view.onFocusChange = onFocusChange
        view.onClick = onClick
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
    /// layout); nil for anything else.
    static func panelEquivalentCommand(_ event: NSEvent) -> Command? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command] else { return nil }
        if event.keyCode == 51 { return .deleteCursor }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let latin = characters.unicodeScalars.allSatisfy(\.isASCII)
        if characters == "z" || (!latin && event.keyCode == 6) { return .undoDelete }
        return nil
    }

    final class KeyView: NSView {
        var onCommand: ((Command) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?
        var onClick: (() -> Bool)? {
            didSet { watchPanelClicks() }
        }
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

        override func keyDown(with event: NSEvent) {
            guard holdsPanelKeyboard(), let command = SessionsPanelKeyView.panelKeyCommand(event) else {
                super.keyDown(with: event)
                return
            }
            // Esc with no terminal on screen: the keyboard just goes.
            if onCommand?(command) != true, command == .handBack { window?.makeFirstResponder(nil) }
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

        /// A local monitor while it is in a window and someone listens.
        private func watchPanelClicks() {
            guard window != nil, onClick != nil else {
                stopWatchingPanelClicks()
                return
            }
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.panelClicked(event) }
                return event
            }
        }

        /// A click on the list's empty space: the keyboard comes here once
        /// the click is handled (the list would otherwise keep it).
        private func panelClicked(_ event: NSEvent) {
            guard let window, event.window === window,
                  convert(bounds, to: nil).contains(event.locationInWindow),
                  onClick?() == true else { return }
            DispatchQueue.main.async { [weak self] in self?.takePanelKeyboard() }
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
        hasKeyboard: Binding<Bool>,
        hoveredRow: Binding<Int64?>
    ) -> some View {
        background(SessionsPanelKeyView(
            keyboardRequest: vm.panelKeyboardSerial,
            onCommand: { SessionsPanelKeyCommands(vm: vm, projectID: projectID, actions: actions).performPanelKey($0) },
            onFocusChange: { has in
                hasKeyboard.wrappedValue = has
                if has { vm.enterPanelKeyboard(projectID: projectID) }
            },
            onClick: { hoveredRow.wrappedValue == nil }
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
