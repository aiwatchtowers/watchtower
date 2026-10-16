import SwiftUI
import WatchtowerCore

/// What the Workbench menu acts on (issue #288). The Workbench tab
/// publishes it as a scene value, so the menu is on only while that tab is
/// in the key window; on other tabs and windows it is greyed out and its
/// chords stay theirs (⌘K is AI Chat's Search Chats there).
@MainActor
struct WorkbenchMenuContext {
    let vm: WorkbenchesViewModel
    /// The Go to… palette is open: nothing changes the page behind it.
    var paletteOpen = false
    let openGoTo: () -> Void

    /// ⌘T and ⌘1…⌘9 act on a workbench page.
    var canUseSessionKeys: Bool { !paletteOpen && vm.hasWorkbenchPage }
    var canTogglePanel: Bool { !paletteOpen }
    /// ⌘[ (board #743): while the workbench list is off screen.
    var canGoBack: Bool { !paletteOpen && vm.canShowAllWorkbenches }
    var panelToggleTitle: String { vm.panelVisible ? "Hide Sessions Panel" : "Show Sessions Panel" }
}

private struct WorkbenchMenuContextKey: FocusedValueKey {
    typealias Value = WorkbenchMenuContext
}

extension FocusedValues {
    var workbenchMenu: WorkbenchMenuContext? {
        get { self[WorkbenchMenuContextKey.self] }
        set { self[WorkbenchMenuContextKey.self] = newValue }
    }
}

/// The menu bar's Workbench menu (issue #288): the workbench page's chords,
/// so macOS prints each next to its item. The only binding of each chord —
/// the title row keeps its buttons, without shortcuts.
struct WorkbenchCommands: Commands {
    @FocusedValue(\.workbenchMenu) private var context
    let appState: AppState

    var body: some Commands {
        CommandMenu("Workbench") {
            Button("New Session") {
                if let vm = context?.vm { Task { await vm.newSessionOnPage() } }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(context?.canUseSessionKeys != true)
            // Inside the Files editor Monaco keeps ⌘K and ⌘[ (the page
            // consumes them before the menu sees them).
            Button("Go to…") { context?.openGoTo() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(context == nil)
            Button(context?.panelToggleTitle ?? "Show Sessions Panel") {
                if let vm = context?.vm { vm.panelVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(context?.canTogglePanel != true)
            Button("Back to Workbenches") { context?.vm.showAllWorkbenches() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(context?.canGoBack != true)
            Divider()
            // Board #412: the one key that may take the keyboard from the
            // terminal — the owner's explicit chord; the bare A stays the
            // page's (`WorkbenchTitleRow.pressOnPage`). Gated on the key
            // window's workbench, as the Navigate menu is (ruling R36).
            Button("Show Waiting for You") { _ = appState.workbenchesViewModel?.openStackFromKeyboard() }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(appState.workbenchesViewModel?.canShowWaitingStack(
                    shownID: appState.openQuicklyCenter.keyWorkbench?.id
                ) != true)
            Divider()
            // ⌘1…⌘9: the sessions panel's numbering (`openSession(atShortcut:)`).
            Menu("Sessions") {
                ForEach(1...SessionSwitcherPresentation.maxShortcut, id: \.self) { n in
                    Button("Session \(n)") {
                        if let vm = context?.vm { Task { await vm.openSession(atShortcut: n) } }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                    .disabled(context?.canUseSessionKeys != true)
                }
            }
        }
    }
}

/// Help menu additions, after the stock Help search and app help.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.sceneID) }
        }
    }
}
