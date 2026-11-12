import AppKit
import SwiftUI
import WatchtowerCore

/// View → Show/Hide Sessions Panel or Show/Hide Inbox Folders (⌥⌘S): one
/// item for the chord, titled for the screen (`PanelToggleTarget.resolve`),
/// the `ItemShortcutCommands` precedent for a chord two screens share. The
/// only binding of ⌥⌘S: the Workbench menu keeps its Show/Hide Sessions
/// Panel item without a key equivalent.
struct PanelToggleCommands: Commands {
    @FocusedValue(\.workbenchMenu) private var workbench
    let appState: AppState

    private var target: PanelToggleTarget? {
        PanelToggleTarget.resolve(
            workbenchCanToggle: workbench?.canTogglePanel == true,
            workbenchPanelShown: workbench?.vm.panelVisible == true,
            // The Workbench page publishes its menu context in its window only.
            workbenchWindowIsKey: workbench != nil,
            inboxOnScreen: appState.selectedDestination == .inbox && appState.actionStripViewModel != nil,
            inboxRailHidden: appState.actionStripViewModel?.railHidden == true
        )
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            let target = target
            Button(target?.title ?? "Show Inbox Folders") { toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(target == nil)
        }
    }

    /// Re-resolved when the chord fires, and only while the page's window
    /// itself is key (`WorkbenchCommands.pageTakesKeys`).
    private func toggle() {
        guard WorkbenchCommands.pageTakesKeys(NSApp.keyWindow) else { return }
        switch target {
        case .workbenchSessions: workbench?.vm.panelVisible.toggle()
        case .inboxFolders: appState.actionStripViewModel?.railHidden.toggle()
        case nil: break
        }
    }
}
