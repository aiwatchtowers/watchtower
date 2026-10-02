import SwiftUI
import WatchtowerCore

/// The branch button's popover (#233): find a local branch and switch to
/// it, start a new branch from the current one, copy the name. Git runs in
/// the CLI; a dirty tree or a live Claude Code session comes back as a
/// confirmation, shown here — never a discard or a force. Errors stay as
/// text in the popover.
struct WorkbenchBranchPopover: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @State private var query = ""
    @State private var isNaming = false
    @State private var newName = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool

    var body: some View {
        let id = project.id
        let pending = vm.pendingBranchConfirmation[id]
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find branch", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Text("LOCAL BRANCHES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            branchList
            Divider()
            newBranchRow
            Button {
                vm.copyBranchName(projectID: id)
            } label: {
                Label("Copy branch name", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            messages
        }
        .padding(10)
        .frame(width: 320)
        .task(id: id) {
            searchFocused = true
            await vm.loadBranches(project: project)
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { vm.pendingBranchConfirmation[id] != nil },
                set: { if !$0 { vm.cancelPendingSwitch(projectID: id) } }
            ),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(pending.primaryLabel) {
                    // The dialog's dismissal clears the pending switch: pass
                    // the one it showed.
                    Task { await vm.confirmPendingSwitch(project: project, confirming: pending) }
                }
            }
            Button("Cancel", role: .cancel) { vm.cancelPendingSwitch(projectID: id) }
        } message: {
            Text(pending?.message ?? "")
        }
    }

    /// The list, a spinner only while the first read runs, the failure
    /// otherwise. A list a later read could not refresh stays visible but
    /// disabled: switching from stale rows would guess.
    @ViewBuilder
    private var branchList: some View {
        let id = project.id
        let state = vm.branchListStates[id] ?? .loading
        let failed: String? = if case .failed(let message) = state { message } else { nil }
        if let failed { caption(failed, color: .red) }
        if let list = vm.gitBranches[id] {
            let rows = WorkbenchBranchPresentation.matchingBranches(list.branches, query: query)
            if rows.isEmpty {
                if failed == nil {
                    Text(list.branches.isEmpty ? "No local branches yet." : "No branch matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if failed != nil {
                    Text("The list may be out of date.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { branch in
                            WorkbenchBranchRow(
                                branch: branch,
                                badge: WorkbenchBranchPresentation.badge(for: branch.name, in: vm.branchTargets[id] ?? [:]),
                                switching: vm.switchingBranch[id]
                            ) {
                                Task { await vm.switchBranch(branch.name, project: project) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(failed != nil)
            }
        } else if failed == nil {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var newBranchRow: some View {
        if isNaming {
            HStack(spacing: 6) {
                TextField("New branch name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
                Button("Create", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || vm.switchingBranch[project.id] != nil)
                Button("Cancel") {
                    isNaming = false
                    newName = ""
                }
            }
            .controlSize(.small)
        } else {
            Button {
                isNaming = true
                nameFocused = true
            } label: {
                Label("New branch from current…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(vm.switchingBranch[project.id] != nil)
        }
    }

    @ViewBuilder
    private var messages: some View {
        let id = project.id
        if let error = vm.gitErrors[id] { caption(error, color: .red) }
        if let status = vm.gitStatusErrors[id] { caption(status, color: .red) }
        if let notice = vm.gitNotices[id] { caption(notice, color: .secondary) }
        // Selectable: it names the stash entry and how to apply it. Stays
        // until dismissed — reopening the popover does not clear it.
        if let stash = vm.gitStashNotes[id] {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                caption(stash.text, color: stash.isError ? .red : .secondary)
                Spacer(minLength: 0)
                Button {
                    vm.dismissStashNote(projectID: id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Dismiss — the stash entry stays on the stack")
                .accessibilityLabel("Dismiss stash note")
            }
        }
    }

    /// A message line: wraps, and can be selected to copy git's words.
    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func create() {
        let name = newName
        Task {
            if await vm.createBranch(name, project: project) {
                isNaming = false
                newName = ""
            }
        }
    }
}

/// One local branch: a checkmark on the current one, the name (with the
/// worktree caption when it is open elsewhere, which disables the row), the
/// board badge and when its tip was committed.
struct WorkbenchBranchRow: View {
    let branch: WorkbenchGitBranch
    let badge: WorkbenchBranchPresentation.Badge?
    /// The branch a switch is running for, if any.
    let switching: String?
    let onSwitch: () -> Void

    var body: some View {
        let caption = WorkbenchBranchPresentation.disabledCaption(branch)
        Button {
            if !branch.current { onSwitch() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .opacity(branch.current ? 1 : 0)
                    .accessibilityHidden(!branch.current)
                VStack(alignment: .leading, spacing: 0) {
                    Text(branch.name)
                        .font(.callout.weight(branch.current ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caption {
                        Text(caption).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let gone = WorkbenchBranchPresentation.upstreamCaption(branch) {
                        Text(gone).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 4)
                if switching == branch.name { ProgressView().controlSize(.mini) }
                if let badge {
                    Text(badge.text)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .help(badge.help)
                }
                if let committed = branch.committedAt {
                    Text(TimeFormatting.relativeTime(from: committed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(branch.current ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(caption != nil || switching != nil)
        .help(branch.name)
    }
}
