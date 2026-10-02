import SwiftUI
import WatchtowerCore

/// `› ⎇ main ● ↑2 ▾` after the folder in the workbench header (#233): the
/// branch button and its popover, or nothing when the folder is not a
/// readable git work tree (or git is not installed).
struct WorkbenchBranchCrumb: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @State private var showsPopover = false

    var body: some View {
        if let status = vm.gitStatus[project.id], WorkbenchBranchPresentation.showsButton(status) {
            HStack(spacing: 4) {
                Text("›")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                WorkbenchBranchButton(status: status, busy: vm.switchingBranch[project.id] != nil) {
                    showsPopover.toggle()
                }
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    WorkbenchBranchPopover(vm: vm, project: project)
                }
            }
        }
    }
}

/// The branch button: branch icon, bold name (a detached HEAD's short hash
/// in gray), an orange dot for uncommitted changes, ahead/behind counters
/// only when nonzero, a chevron. Long names truncate; the tooltip has the
/// full name and any operation in progress.
struct WorkbenchBranchButton: View {
    let status: WorkbenchGitStatus
    var busy = false
    let action: () -> Void

    var body: some View {
        let label = WorkbenchBranchPresentation.label(status)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                // Capped in characters, not points: a flexible frame would
                // take the header's spare width. The tooltip has it all.
                let name = WorkbenchBranchPresentation.capped(label.text)
                if label.style == .detachedHash {
                    Text(name).foregroundStyle(.secondary).monospaced().lineLimit(1)
                } else {
                    Text(name).bold().lineLimit(1)
                }
                if status.dirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Uncommitted changes")
                }
                if let counters = WorkbenchBranchPresentation.counters(status) {
                    Text(counters).foregroundStyle(.secondary).monospacedDigit()
                }
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(WorkbenchBranchPresentation.help(status))
        .accessibilityLabel("Branch \(label.text)")
    }
}
