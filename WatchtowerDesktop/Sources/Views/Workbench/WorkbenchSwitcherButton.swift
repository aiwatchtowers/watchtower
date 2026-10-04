import SwiftUI
import WatchtowerCore

/// What the switcher's two list actions do; the workbench list owns the
/// create flow (folder panel, TCC warning) and the panel's visibility.
struct WorkbenchSwitcherActions {
    /// "New Workbench…": the workbench list's New Workbench… flow.
    let newWorkbench: () -> Void
    /// "All Workbenches": level 1, the panel shown.
    let showAll: () -> Void
}

/// `▦ <workbench> ▾` (board #250, variant F): the workbench switcher's
/// button and its popover. The sessions panel's header fills its width
/// with it; the collapsed title row (#251) sizes it to the name.
struct WorkbenchSwitcher: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let actions: WorkbenchSwitcherActions
    var fillsWidth = true
    @State private var showsPopover = false

    var body: some View {
        WorkbenchSwitcherButton(name: project.name, fillsWidth: fillsWidth) { showsPopover.toggle() }
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
                .popoverSurface()
            }
    }
}

/// The switcher's button: grid icon, the workbench's name in semibold (long
/// names truncate, the tooltip has it all), a chevron; the whole width is
/// the click target.
struct WorkbenchSwitcherButton: View {
    let name: String
    var fillsWidth = true
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
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(name) — Switch Workbench")
        .accessibilityLabel("Workbench \(name)")
        .accessibilityHint("Switch workbench")
    }
}
