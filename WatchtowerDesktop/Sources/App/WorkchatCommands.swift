import AppKit
import SwiftUI
import WatchtowerCore

/// The View menu's Show Terminal / Show Workchat (#711): ⌃` swaps the
/// session on screen between its terminal and its Workchat, in place. One
/// item, titled by the mode it switches to; on only while a workbench page
/// shows a session (the Workbench menu's scene value, `WorkbenchMenuContext`).
struct WorkchatCommands: Commands {
    @FocusedValue(\.workbenchMenu) private var context

    /// The terminal or Workchat pane on screen; nil without one (or while
    /// the Go to… palette is open).
    private var sessionPane: WorkspacePane? {
        guard let context, !context.paletteOpen, let projectID = context.vm.selectedWorkbenchID else { return nil }
        return context.vm.visibleSessionPane(projectID: projectID)
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(sessionPane?.isWorkchat == true ? "Show Terminal" : "Show Workchat") {
                guard let context, WorkbenchCommands.pageTakesKeys(NSApp.keyWindow),
                      let projectID = context.vm.selectedWorkbenchID else { return }
                context.vm.toggleWorkchat(projectID: projectID)
            }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(sessionPane == nil)
        }
    }
}
