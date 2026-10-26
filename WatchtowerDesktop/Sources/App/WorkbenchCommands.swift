import AppKit
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

    enum BackAction: Equatable {
        case popSubagent, showAllWorkbenches
    }

    /// What ⌘[ does (#711): the focused session chat pane's open subagent
    /// pops first; without one, the page goes back to the workbench list.
    static func backAction(popAvailable: Bool, paletteOpen: Bool, canShowAll: Bool) -> BackAction? {
        guard !paletteOpen else { return nil }
        if popAvailable { return .popSubagent }
        return canShowAll ? .showAllWorkbenches : nil
    }

    func backAction(popAvailable: Bool) -> BackAction? {
        Self.backAction(popAvailable: popAvailable, paletteOpen: paletteOpen, canShowAll: vm.canShowAllWorkbenches)
    }
}

private struct WorkbenchMenuContextKey: FocusedValueKey {
    typealias Value = WorkbenchMenuContext
}

/// Published by the focused session chat pane while a subagent is open in
/// it: pops one level (⌘[ through View → Back, `ItemShortcutCommands`).
private struct SessionChatPopKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workbenchMenu: WorkbenchMenuContext? {
        get { self[WorkbenchMenuContextKey.self] }
        set { self[WorkbenchMenuContextKey.self] = newValue }
    }

    var sessionChatPop: (() -> Void)? {
        get { self[SessionChatPopKey.self] }
        set { self[SessionChatPopKey.self] = newValue }
    }
}

/// The menu bar's Workbench menu (issue #288): the workbench page's chords,
/// so macOS prints each next to its item. The only binding of each chord —
/// the title row keeps its buttons, without shortcuts.
struct WorkbenchCommands: Commands {
    @FocusedValue(\.workbenchMenu) private var context
    let appState: AppState

    /// The page's chords act only while its window itself is key: a sheet
    /// or alert over it, or a panel (Open Quickly, a popover), keeps them —
    /// as the title row's hidden buttons did. Checked when the chord fires:
    /// the menu's enabled state is not re-read on key-window changes.
    static func pageTakesKeys(_ keyWindow: NSWindow?) -> Bool {
        guard let keyWindow else { return false }
        return !keyWindow.isSheet && keyWindow.attachedSheet == nil && !(keyWindow is NSPanel)
    }

    private func onPage(_ action: (WorkbenchMenuContext) -> Void) {
        guard let context, Self.pageTakesKeys(NSApp.keyWindow) else { return }
        action(context)
    }

    var body: some Commands {
        CommandMenu("Workbench") {
            Button("New Session") {
                onPage { context in Task { await context.vm.newSessionOnPage() } }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(context?.canUseSessionKeys != true)
            // Inside the Files editor Monaco keeps ⌘K and ⌘[ (the page
            // consumes them before the menu sees them).
            Button("Go to…") { onPage { $0.openGoTo() } }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(context == nil)
            Button(context?.panelToggleTitle ?? "Show Sessions Panel") {
                onPage { $0.vm.panelVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(context?.canTogglePanel != true)
            // ⌘[ (Back) and ⌘1…⌘9 (Go to Item) are the View menu's shared
            // items (`ItemShortcutCommands`, spec 2026-10-26 §4, §5.4).
            Divider()
            // Board #412: the one key that may take the keyboard from the
            // terminal — the owner's explicit chord; the bare A stays the
            // page's (`WorkbenchTitleRowKeys.pressOnPage`). Gated on the key
            // window's workbench, as the Navigate menu is (ruling R36).
            Button("Show Waiting for You") { _ = appState.workbenchesViewModel?.openStackFromKeyboard() }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(appState.workbenchesViewModel?.canShowWaitingStack(
                    shownID: appState.openQuicklyCenter.keyWorkbench?.id
                ) != true)
        }
    }
}

/// Help menu additions, after the stock Help search and app help.
struct HelpCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Ask Watchtower…") { appState.askWatchtower() }
                .keyboardShortcut("/", modifiers: .command)
            Button("Watchtower User Guide") { NSWorkspace.shared.open(GuideLinks.readme) }
            Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsView.sceneID) }
        }
    }
}
