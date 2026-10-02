import SwiftUI
import WatchtowerCore

/// `› ⎇ main ● ↑2 ▾` after the folder in the workbench header (#233): the
/// branch button and its popover; nothing when the folder is not a git work
/// tree (or git is not installed); a warning icon when the status could not
/// be read and none is known yet (the CLI is missing, git failed).
struct WorkbenchBranchCrumb: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @State private var showsPopover = false

    var body: some View {
        let error = vm.gitStatusErrors[project.id]
        if let status = vm.gitStatus[project.id], WorkbenchBranchPresentation.showsButton(status) {
            HStack(spacing: 4) {
                Text("›")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                WorkbenchBranchButton(status: status, staleError: error, busy: vm.switchingBranch[project.id] != nil) {
                    showsPopover.toggle()
                }
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    WorkbenchBranchPopover(vm: vm, project: project)
                }
            }
        } else if let error {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(error)
                .accessibilityLabel("Git status unavailable")
        }
    }
}

/// The branch button: branch icon, bold name (a detached HEAD's short hash
/// in gray), an orange dot for uncommitted changes, ahead/behind counters
/// only when nonzero, a chevron. Long names truncate; the tooltip has the
/// full name and any operation in progress. A status the later reads could
/// not refresh is marked stale, its tooltip saying why.
struct WorkbenchBranchButton: View {
    let status: WorkbenchGitStatus
    /// Why the reads since `status` failed; nil when it is current.
    var staleError: String?
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
                if staleError != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Status may be out of date")
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
        .help(WorkbenchBranchPresentation.help(status, staleError: staleError))
        .accessibilityLabel("Branch \(label.text)")
    }
}
