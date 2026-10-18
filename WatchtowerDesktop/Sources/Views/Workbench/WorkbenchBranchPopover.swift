import SwiftUI
import WatchtowerCore

/// The branch button's popover (#233): find a local branch and switch to
/// it, start a new branch from the current one, copy the name. Git runs in
/// the CLI; a dirty tree or a live Claude Code session comes back as a
/// confirmation, shown here — never a discard or a force. Errors stay as
/// text in the popover. It works on `root`, the folder the page shows: the
/// session's worktree or the main folder (board #565). Since board #563 it
/// fetches origin (in the background when due, or from the Fetch button —
/// the view model holds the fetch) and lists origin's remote-only branches
/// to check out.
struct WorkbenchBranchPopover: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let root: CodeRoot
    @State private var query = ""
    @State private var isNaming = false
    @State private var newName = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool

    /// `root` nil: the main folder.
    init(vm: WorkbenchesViewModel, project: Workbench, root: CodeRoot? = nil) {
        self.vm = vm
        self.project = project
        self.root = root ?? project.mainCodeRoot
    }

    var body: some View {
        let key = GitRootKey(root)
        let pending = vm.pendingBranchConfirmation[key]
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find branch", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            fetchRow
            Text("LOCAL BRANCHES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            branchList
            remoteOnlyList
            Divider()
            newBranchRow
            Button {
                vm.copyBranchName(key: key)
            } label: {
                Label("Copy branch name", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            messages
        }
        .padding(10)
        .frame(width: 320)
        .task(id: key) {
            searchFocused = true
            await vm.loadBranches(project: project, root: root)
            vm.fetchOriginIfDue(project: project, root: root)
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { vm.pendingBranchConfirmation[key] != nil },
                set: { if !$0 { vm.cancelPendingSwitch(key: key) } }
            ),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(pending.primaryLabel) {
                    // The dialog's dismissal clears the pending switch: pass
                    // the one it showed.
                    Task { await vm.confirmPendingSwitch(project: project, confirming: pending, root: root) }
                }
            }
            Button("Cancel", role: .cancel) { vm.cancelPendingSwitch(key: key) }
        } message: {
            Text(pending?.message ?? "")
        }
    }

    /// The list, a spinner only while the first read runs, the failure
    /// otherwise. A list a later read could not refresh stays visible but
    /// disabled: switching from stale rows would guess.
    @ViewBuilder
    private var branchList: some View {
        let key = GitRootKey(root)
        let state = vm.branchListStates[key] ?? .loading
        let failed: String? = if case .failed(let message) = state { message } else { nil }
        if let failed { caption(failed, color: .red) }
        if let list = vm.gitBranches[key] {
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
                                badge: WorkbenchBranchPresentation.badge(for: branch.name, in: vm.branchTargets[key] ?? [:]),
                                switching: vm.switchingBranch[key]
                            ) {
                                Task { await vm.switchBranch(branch.name, project: project, root: root) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(failed != nil || !vm.gitRootIsPlaced(key))
            }
        } else if failed == nil {
            ProgressView().controlSize(.small)
        }
    }

    /// "Fetched 2m ago" and the Fetch button; a failed fetch is a quiet
    /// note under it. Nothing without an origin remote, or before a status
    /// placed the repository.
    @ViewBuilder
    private var fetchRow: some View {
        let key = GitRootKey(root)
        if vm.gitFetchRepository(key) != nil {
            let state = vm.gitFetchState(key)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let caption = WorkbenchFetchPresentation.caption(state, now: context.date) {
                    HStack(spacing: 4) {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if state?.running == true {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button {
                                vm.fetchOrigin(project: project, root: root)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Fetch origin (git fetch --prune origin) — never asks for a password")
                            .accessibilityLabel("Fetch origin")
                        }
                    }
                }
            }
            if let failure = state?.failure { caption(failure, color: .secondary) }
        }
    }

    /// Origin's branches with no local copy (board #563); a row checks one
    /// out as a local tracking branch behind the switch's confirmations.
    @ViewBuilder
    private var remoteOnlyList: some View {
        let key = GitRootKey(root)
        if let list = vm.gitBranches[key] {
            let rows = WorkbenchBranchPresentation.matchingRemoteBranches(list.remoteOnly, query: query)
            if !rows.isEmpty || !list.remoteOnlyError.isEmpty {
                Text("REMOTE ONLY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if !list.remoteOnlyError.isEmpty {
                caption("Could not list origin's branches: \(list.remoteOnlyError)", color: .secondary)
            }
            if !rows.isEmpty {
                let failed = if case .failed = vm.branchListStates[key] ?? .loading { true } else { false }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { branch in
                            WorkbenchRemoteBranchRow(branch: branch, switching: vm.switchingBranch[key]) {
                                Task { await vm.checkOutRemoteBranch(branch.name, project: project, root: root) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(failed || !vm.gitRootIsPlaced(key))
            }
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
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || vm.switchingBranch[root] != nil)
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
            .disabled(vm.switchingBranch[root] != nil || !vm.gitRootIsPlaced(GitRootKey(root)))
        }
    }

    @ViewBuilder
    private var messages: some View {
        let key = GitRootKey(root)
        if let error = vm.gitErrors[key] { caption(error, color: .red) }
        if let status = vm.gitStatusErrors[key] { caption(status, color: .red) }
        if let note = vm.gitScopeNotes[key] { caption(note, color: .secondary) }
        if let notice = vm.gitNotices[key] { caption(notice, color: .secondary) }
        // Selectable: it names the stash entry and how to apply it. Stays
        // until dismissed — reopening the popover does not clear it.
        if let stash = vm.gitStashNotes[key] {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                caption(stash.text, color: stash.isError ? .red : .secondary)
                Spacer(minLength: 0)
                Button {
                    vm.dismissStashNote(key: key)
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
            if await vm.createBranch(name, project: project, root: root) {
                isNaming = false
                newName = ""
            }
        }
    }
}

/// One of origin's remote-only branches: its name, when its tip was
/// committed and a "Check out" action.
struct WorkbenchRemoteBranchRow: View {
    let branch: WorkbenchGitRemoteBranch
    /// The branch a switch or checkout is running for, if any.
    let switching: String?
    let onCheckOut: () -> Void

    var body: some View {
        Button(action: onCheckOut) {
            HStack(spacing: 6) {
                Image(systemName: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(branch.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if switching == branch.name { ProgressView().controlSize(.mini) }
                if let committed = branch.committedAt {
                    Text(TimeFormatting.relativeTime(from: committed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Check out")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switching != nil)
        .help("Check out \(branch.ref) as a local branch tracking it")
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
