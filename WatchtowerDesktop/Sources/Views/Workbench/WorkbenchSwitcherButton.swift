import SwiftUI
import WatchtowerCore

/// What the switcher's two list actions do; the workbench list owns the
/// create flow (folder panel, TCC warning) and the panel's visibility.
struct WorkbenchSwitcherActions {
    /// "Open Folder…": the workbench list's Open Folder… flow.
    let openFolder: () -> Void
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
                    onOpenFolder: {
                        showsPopover = false
                        // The folder panel runs modally: after the popover is gone.
                        DispatchQueue.main.async { actions.openFolder() }
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

/// `‹` left of the workbench's name (board #743): one click back to the
/// workbench list, the visible twin of ⌘[ and the switcher's "All
/// Workbenches".
struct WorkbenchBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
        }
        .buttonStyle(.borderless)
        .help("All Workbenches (⌘[)")
        .accessibilityLabel("Back to Workbenches")
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
