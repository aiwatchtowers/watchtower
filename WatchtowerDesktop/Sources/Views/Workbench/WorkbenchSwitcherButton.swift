import SwiftUI
import WatchtowerCore

/// What the switcher's two list actions do; the workbench list owns the
/// create flow (folder panel, TCC warning) and the panel's visibility.
struct WorkbenchSwitcherActions {
    /// "＋ Новый workbench…": the workbench list's New Workbench… flow.
    let newWorkbench: () -> Void
    /// "‹ Все workbench" (⌘⇧O): level 1, the panel shown.
    let showAll: () -> Void
}

/// `▦ <workbench> ▾` (board #250, variant F): the workbench switcher's
/// button and its popover. The sessions panel's header fills its width
/// with it.
struct WorkbenchSwitcher: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let actions: WorkbenchSwitcherActions
    @State private var showsPopover = false

    var body: some View {
        WorkbenchSwitcherButton(name: project.name) { showsPopover.toggle() }
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                WorkbenchSwitcherPopover(
                    vm: vm,
                    currentID: project.id,
                    onSelect: { id in
                        showsPopover = false
                        Task { await vm.switchTo(workbenchID: id) }
                    },
                    onNewWorkbench: {
                        showsPopover = false
                        // The save panel runs modally: after the popover is gone.
                        DispatchQueue.main.async { actions.newWorkbench() }
                    },
                    onShowAll: {
                        showsPopover = false
                        actions.showAll()
                    }
                )
            }
    }
}

/// The switcher's button: grid icon, the workbench's name in semibold (long
/// names truncate, the tooltip has it all), a chevron; the whole width is
/// the click target.
struct WorkbenchSwitcherButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(name) — сменить workbench")
        .accessibilityLabel("Workbench \(name)")
        .accessibilityHint("Сменить workbench")
    }
}
