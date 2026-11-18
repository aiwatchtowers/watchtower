import AppKit
import SwiftUI
import WatchtowerCore

/// The FILES section at the bottom of the sessions panel. Collapsed it is
/// one header row pinned to the panel's bottom edge; open it shows the
/// workbench folder as a tree, resizable by dragging its top edge. A file
/// click opens it in the Files pane (`WorkbenchesViewModel.openFile`); the
/// header's + and each row's menu create, rename and trash entries, the
/// name typed in place in the tree. A bench of several folders (#2003,
/// spec §6.2) shows one root row per folder, each with its own tree; a
/// one-folder bench keeps today's tree and adds the quiet Put on the
/// Bench… hint under it.
struct WorkbenchFilesSection: View {
    static let heightRange: ClosedRange<Double> = 120...700
    private typealias Copy = WorkbenchFolderPresentation

    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    /// The root the page works in (a folder or a session's worktree): the
    /// header's caption and + act on it, and its folder's root is open.
    let root: CodeRoot
    /// Put on the Bench… (the folder panel and its TCC confirmation are the page's).
    let putOnBench: () -> Void
    @AppStorage("workbench.files.expanded") private var isExpanded = false
    @AppStorage("workbench.files.height") private var height: Double = 300
    @State private var liveHeight: Double?
    @State private var cursorPushed = false
    @State private var edit: CodeTreeEdit?
    /// The root `edit` types in (several trees may be open).
    @State private var editRoot: CodeRoot?
    @State private var trashing: CodeFileEntry?
    @State private var trashingRoot: CodeRoot?
    /// The folder's file count for the Trash confirmation, counted off the
    /// main thread.
    @State private var trashCount: Int?
    @State private var operationError: String?
    /// Remove from Bench…'s confirmation or refusal on screen.
    @State private var removing: RemoveFolder?
    /// Locate… waiting on the TCC warning: the folder and its new place.
    @State private var locating: (folder: WorkbenchFolder, url: URL)?
    @State private var sensitiveLocation: String?

    /// A folder and the remove dialog about it.
    private struct RemoveFolder {
        let folder: WorkbenchFolder
        let dialog: WorkbenchFolderPresentation.RemoveDialog
    }

    var body: some View {
        let files = vm.codeFiles
        let tree = files.tree(for: root)
        let roots = vm.filesRoots(project: project, active: root)
        VStack(spacing: 0) {
            if isExpanded { resizeHandle } else { Divider() }
            header(tree)
            if isExpanded {
                notices(files)
                if WorkbenchesViewModel.showsRootRows(roots) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(roots) { rootSection($0, files: files) }
                        }
                        .padding(.horizontal, Spacing.small)
                        .padding(.bottom, Spacing.compact)
                    }
                    .frame(height: liveHeight ?? height)
                } else {
                    CodeFileTreeList(
                        tree: tree,
                        rootLine: CodeFilesRootLine(root: root, status: vm.gitStatus[root], staleError: vm.gitStatusErrors[root]),
                        activeFile: files.tabs(for: root).active,
                        git: files.git(for: root),
                        edit: editBinding(root),
                        actions: rowActions(tree, root: root)
                    )
                    .frame(height: liveHeight ?? height)
                    // Keyed by the code root: the panel is not rebuilt when a deep
                    // link switches workbenches, and each root counts as shown
                    // exactly while this runs.
                    .task(id: root) {
                        tree.loadIfNeeded()
                        await files.show(root)
                    }
                    hint
                }
            }
        }
        .task(id: project.id) {
            await vm.loadBenchFolders(projectID: project.id)
            if vm.liveFolders(projectID: project.id).count > 1 { await vm.refreshFolderInstall(projectID: project.id) }
        }
        .confirmationDialog(
            "Move “\(trashing?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = trashing { moveToTrash(entry, root: trashingRoot ?? root) }
                trashing = nil
            }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text(trashMessage)
        }
        .alert(
            removing?.dialog.title ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { pending in
            if pending.dialog.confirms {
                Button(Copy.cancel, role: .cancel) {}
                Button(Copy.remove, role: .destructive) { remove(pending.folder) }
            } else {
                Button(Copy.ok, role: .cancel) {}
            }
        } message: { pending in
            Text(pending.dialog.message)
        }
        .sensitiveLocationAlert($sensitiveLocation) {
            if let pending = locating { Task { await vm.locateFolder(pending.folder, to: pending.url) } }
            locating = nil
        } onCancel: {
            locating = nil
        }
        .alert(
            "Could not change the files",
            isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    /// One folder of a several-folder bench: its row and, open, its tree.
    @ViewBuilder
    private func rootSection(_ item: FilesRootItem, files: CodeFilesCenter) -> some View {
        FilesRootRow(
            name: item.name, caption: item.caption, path: item.folder.folderPath, state: item.state,
            branchLine: item.branchLine, isExpanded: item.isExpanded, isHighlighted: item.isHighlighted,
            actions: rootActions(item)
        )
        if item.isExpanded {
            let tree = files.tree(for: item.root)
            // One stack, so the task below runs once (the rows are a group).
            VStack(alignment: .leading, spacing: 0) {
                CodeFileTreeRows(
                    tree: tree,
                    activeFile: files.tabs(for: item.root).active,
                    git: files.git(for: item.root),
                    edit: editBinding(item.root),
                    actions: rowActions(tree, root: item.root)
                )
            }
            .task(id: item.root) {
                tree.loadIfNeeded()
                await files.show(item.root)
            }
        }
    }

    private func rootActions(_ item: FilesRootItem) -> FilesRootActions {
        let projectID = project.id
        let url = item.folder.url
        var actions = FilesRootActions(
            toggle: { vm.toggleFolderRoot(item.folder.id, projectID: projectID) },
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            retryInstall: { Task { await vm.retryFolderInstall(projectID: projectID) } }
        )
        // A new session of the default agent in this folder (§6.4).
        actions.newSessionHere = {
            Task { await vm.newSession(projectID: projectID, folder: .filesRoot(vm.folderRoot(item.folder))) }
        }
        actions.locate = { locate(item.folder) }
        // The bench's only folder cannot leave it (a missing one is located instead).
        if vm.canRemoveFolder(projectID: projectID) {
            actions.removeFromBench = { removing = RemoveFolder(folder: item.folder, dialog: vm.removeDialog(item.folder)) }
        }
        return actions
    }

    /// Locate… (§6.3): the folder panel, Open Folder…'s TCC warning when the
    /// new place needs it, then `workbench folder locate`.
    private func locate(_ folder: WorkbenchFolder) {
        guard let url = WorkbenchesView.runFolderPanel(
            title: Copy.locatePanelTitle(name: folder.name), prompt: Copy.locatePanelPrompt, canCreate: false
        ) else { return }
        Task {
            if case let .confirmLocation(location) = await vm.locate(folder, to: url) {
                locating = (folder, url)
                sensitiveLocation = location
            }
        }
    }

    /// Remove after its confirmation; Go's own refusal (a session started
    /// meanwhile) comes back as the dialog to show.
    private func remove(_ folder: WorkbenchFolder) {
        Task {
            if let refused = await vm.removeFromBench(folder) {
                removing = RemoveFolder(folder: folder, dialog: refused)
            }
        }
    }

    /// Under a one-folder tree: `Task touches another repo? Put on the Bench…`.
    private var hint: some View {
        HStack(spacing: Spacing.small) {
            Text(Copy.hintLead).foregroundStyle(.tertiary)
            Button(Copy.putOnBenchTitle, action: putOnBench)
                .buttonStyle(.kitQuiet)
                .foregroundStyle(Color.accentColor)
                .disabled(vm.puttingOnBench.contains(project.id))
        }
        .font(.caption2)
        .padding(.horizontal, Spacing.medium)
        .padding(.bottom, Spacing.compact)
    }

    /// `edit` as the tree of `root` sees it: only the root it types in has one.
    private func editBinding(_ root: CodeRoot) -> Binding<CodeTreeEdit?> {
        Binding(
            get: { editRoot == root ? edit : nil },
            set: { value in
                edit = value
                editRoot = value == nil ? nil : root
            }
        )
    }

    private var trashMessage: String {
        guard let entry = trashing else { return "" }
        let saved = "Unsaved edits are saved first, so the Trash keeps them."
        guard entry.isDirectory else { return "You can put it back from the Trash. Its tab closes. \(saved)" }
        let count = trashCount.map { "It holds \($0) file\($0 == 1 ? "" : "s"). " } ?? ""
        return "\(count)You can put it back from the Trash. Tabs of files in it close. \(saved)"
    }

    private func confirmTrash(_ entry: CodeFileEntry, root: CodeRoot) {
        trashCount = nil
        trashingRoot = root
        trashing = entry
        guard entry.isDirectory else { return }
        let url = root.folder.appendingPathComponent(entry.relPath)
        Task {
            let count = await Task.detached { CodeFilesCenter.fileCount(at: url) }.value
            if trashing == entry { trashCount = count }
        }
    }

    private func header(_ tree: CodeFileTree) -> some View {
        CodeFilesHeader(
            root: root,
            isExpanded: isExpanded,
            toggle: { withAnimation(Motion.toggle) { isExpanded.toggle() } },
            newEntry: { folder in startCreate(folder: folder, in: "", tree: tree, root: root) },
            collapseAll: tree.collapseAll,
            reload: tree.reloadAll,
            putOnBench: CodeFilesHeader.PutOnBench(
                action: putOnBench, isDisabled: vm.puttingOnBench.contains(project.id)
            )
        )
    }

    @ViewBuilder
    private func notices(_ files: CodeFilesCenter) -> some View {
        if let error = vm.putOnBenchErrors[project.id] {
            Text(error)
                .font(.caption2)
                .foregroundStyle(Tone.error)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.medium)
        }
        if let warning = vm.mergeWarnings[project.id] {
            Text(warning)
                .font(.caption2)
                .foregroundStyle(Tone.warning)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.medium)
        }
        if let error = files.watchErrors[root] {
            Text(error).font(.caption2).foregroundStyle(Tone.warning).padding(.horizontal, Spacing.medium)
        }
        if let error = files.gitErrors[root] {
            Text(CodeFilesCopy.gitUnavailable)
                .font(.caption2)
                .foregroundStyle(Tone.warning)
                .padding(.horizontal, Spacing.medium)
                .help(error)
        }
    }

    private func rowActions(_ tree: CodeFileTree, root: CodeRoot) -> CodeFileTreeList.Actions {
        CodeFileTreeList.Actions(
            open: { entry, preview in
                if entry.isDirectory {
                    tree.toggle(entry.relPath)
                } else {
                    // Another folder's file: its root becomes the page's (§6.8).
                    vm.selectFilesRoot(root, project: project)
                    Task { await vm.openFile(entry.relPath, root: root, preview: preview) }
                }
            },
            newEntry: { entry, folder in
                startCreate(
                    folder: folder, in: entry.isDirectory ? entry.relPath : CodeFilesCenter.parent(entry.relPath),
                    tree: tree, root: root
                )
            },
            rename: { entry in
                editRoot = root
                edit = CodeTreeEdit(kind: .rename(entry.relPath), text: entry.name)
            },
            trash: { confirmTrash($0, root: root) },
            commit: commit,
            root: root.folder
        )
    }

    private func startCreate(folder: Bool, in directory: String, tree: CodeFileTree, root: CodeRoot) {
        isExpanded = true
        tree.expand(directory)
        editRoot = root
        edit = CodeTreeEdit(kind: .create(folder: folder, in: directory), text: "")
    }

    /// Return in the name field. A rename in flight ignores another Return,
    /// and its result only touches the field it started from.
    private func commit() {
        guard var current = edit, !current.isCommitting else { return }
        let root = editRoot ?? root
        let files = vm.codeFiles
        switch current.kind {
        case let .create(folder, directory):
            do {
                if folder {
                    try files.createFolder(current.text, in: directory, root: root)
                } else {
                    try files.createFile(current.text, in: directory, root: root)
                    vm.showFilesPane(projectID: root.workbenchID)
                }
                edit = nil
            } catch {
                current.error = error.localizedDescription
                edit = current
            }
        case let .rename(path):
            let text = current.text
            current.isCommitting = true
            edit = current
            let started = current.kind
            Task {
                do {
                    try await files.rename(path, to: text, root: root)
                    if edit?.kind == started { edit = nil }
                } catch {
                    guard edit?.kind == started else { return }
                    current.isCommitting = false
                    current.error = error.localizedDescription
                    edit = current
                }
            }
        }
    }

    private func moveToTrash(_ entry: CodeFileEntry, root: CodeRoot) {
        Task {
            do {
                try await vm.codeFiles.moveToTrash(entry.relPath, root: root)
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    /// The open section's top edge: drag up to grow it.
    private var resizeHandle: some View {
        Divider()
            .padding(.vertical, Spacing.tight)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !cursorPushed {
                    NSCursor.resizeUpDown.push()
                    cursorPushed = true
                } else if !inside {
                    popCursor()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let proposed = height - Double(value.translation.height)
                        liveHeight = min(max(proposed, Self.heightRange.lowerBound), Self.heightRange.upperBound)
                    }
                    .onEnded { _ in
                        if let liveHeight { height = liveHeight }
                        liveHeight = nil
                    }
            )
            .onDisappear { popCursor() }
            .accessibilityHidden(true)
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

/// A name being typed in the tree: a new entry in a folder, or a rename.
struct CodeTreeEdit: Equatable {
    enum Kind: Equatable {
        case create(folder: Bool, in: String)
        case rename(String)
    }

    var kind: Kind
    var text: String
    var error: String?
    var isCommitting = false
}

/// The FILES header: the section's toggle under a sidebar-style caption
/// (`FILES`, or `FILES — ⑂ name` in a worktree), and while open its icon
/// buttons — Put on the Bench… (#2003), new entry, collapse all, reload —
/// always on view.
struct CodeFilesHeader: View {
    /// The header's Put on the Bench… button (the folder panel is the page's).
    struct PutOnBench {
        let action: () -> Void
        let isDisabled: Bool
    }

    let root: CodeRoot
    let isExpanded: Bool
    let toggle: () -> Void
    let newEntry: (_ folder: Bool) -> Void
    let collapseAll: () -> Void
    let reload: () -> Void
    var putOnBench: PutOnBench?

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Button(action: toggle) {
                HStack(spacing: Spacing.compact) {
                    CodeTreeChevron(isExpanded: isExpanded)
                    Text(root.filesCaption).sidebarSectionLabel()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(CodeFilesCopy.captionHelp(root))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ListLayout.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? CodeFilesCopy.collapse : CodeFilesCopy.expand)
            .accessibilityAddTraits(.isHeader)
            if isExpanded {
                if let putOnBench {
                    Button(action: putOnBench.action) {
                        Image(systemName: WorkbenchFolderPresentation.putOnBenchIcon)
                    }
                    .buttonStyle(.kitIcon(isOn: false))
                    .disabled(putOnBench.isDisabled)
                    .help(WorkbenchFolderPresentation.tooltip)
                    .accessibilityLabel(WorkbenchFolderPresentation.tooltip)
                }
                Menu {
                    Button(CodeFilesCopy.newFile) { newEntry(false) }
                    Button(CodeFilesCopy.newFolder) { newEntry(true) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.kitIcon(isOn: false))
                .menuIndicator(.hidden)
                .fixedSize()
                .help(CodeFilesCopy.newEntry)
                .accessibilityLabel(CodeFilesCopy.newEntry)
                Button(action: collapseAll) {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.kitIcon(isOn: false))
                .help(CodeFilesCopy.collapseAll)
                .accessibilityLabel(CodeFilesCopy.collapseAll)
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.kitIcon(isOn: false))
                .help(CodeFilesCopy.reload)
                .accessibilityLabel(CodeFilesCopy.reload)
            }
        }
        .padding(.leading, Spacing.medium)
        .padding(.trailing, Spacing.compact)
        .padding(.vertical, Spacing.tight)
    }
}

/// A disclosure chevron of the tree: small, tertiary, turned down when open.
private struct CodeTreeChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: IconSize.chevron, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: Spacing.cozy)
            .accessibilityHidden(true)
    }
}

/// The tree's indentation: every row at `depth` starts its chevron slot at
/// `leading(depth)`; text under a row (an error, the empty folder) lines up
/// with the icon of a row one level deeper.
private enum CodeTreeIndent {
    static func leading(_ depth: Int) -> CGFloat {
        Spacing.compact + CGFloat(depth) * Spacing.medium
    }

    /// Where a row's icon starts: past the chevron slot.
    static func icon(_ depth: Int) -> CGFloat {
        leading(depth) + Spacing.cozy + Spacing.small
    }
}

/// The tree's visible rows under its root row (the folder, its branch and
/// git status on the right; closing it hides the tree): folders toggle on
/// click; a file opens in a preview tab on a single click and in a kept tab
/// on a double click. Uncommitted files carry their git mark and tint, a
/// folder holding one a dot. A folder that could not be read says so under
/// its row; an empty root says so under the root row.
struct CodeFileTreeList: View {
    struct Actions {
        let open: (CodeFileEntry, _ preview: Bool) -> Void
        let newEntry: (CodeFileEntry, _ folder: Bool) -> Void
        let rename: (CodeFileEntry) -> Void
        let trash: (CodeFileEntry) -> Void
        let commit: () -> Void
        let root: URL
    }

    let tree: CodeFileTree
    let rootLine: CodeFilesRootLine
    let activeFile: String?
    let git: GitStatusSnapshot
    @Binding var edit: CodeTreeEdit?
    let actions: Actions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CodeFilesRootRow(line: rootLine, isExpanded: tree.isRootExpanded) { tree.toggle("") }
                if tree.isRootExpanded {
                    CodeFileTreeRows(tree: tree, activeFile: activeFile, git: git, edit: $edit, actions: actions)
                }
            }
            .padding(.horizontal, Spacing.compact)
            .padding(.bottom, Spacing.compact)
        }
    }
}

/// A tree's rows under its root row, without the row: the one-folder list's
/// (under `CodeFilesRootRow`) and each open root's on a several-folder bench
/// (under `FilesRootRow`, #2003). A group, so the rows sit in the caller's
/// lazy stack.
struct CodeFileTreeRows: View {
    let tree: CodeFileTree
    let activeFile: String?
    let git: GitStatusSnapshot
    @Binding var edit: CodeTreeEdit?
    let actions: CodeFileTreeList.Actions

    var body: some View {
        Group {
            if let error = tree.errors[""] {
                note(error, depth: 0, tone: Tone.error)
            } else if tree.listings[""]?.isEmpty == true, !isCreatingAtRoot {
                note(CodeFilesRootLine.emptyFolder, depth: 0, tone: nil)
            }
            if isCreatingAtRoot { nameField(depth: 1) }
            ForEach(tree.rows, id: \.entry.relPath) { row in
                rowView(row)
            }
        }
    }

    private var isCreatingAtRoot: Bool {
        if case .create(_, "")? = edit?.kind { return true }
        return false
    }

    @ViewBuilder
    private func rowView(_ row: CodeFileTree.Row) -> some View {
        // The root row sits at depth 0, so the tree's rows start one deeper.
        let depth = row.depth + 1
        let path = row.entry.relPath
        if case .rename(path)? = edit?.kind {
            nameField(depth: depth)
        } else {
            CodeFileTreeRow(
                row: row, depth: depth, isOpen: activeFile == path, root: actions.root,
                status: git.files[path], holdsChanges: row.entry.isDirectory && git.dirtyDirectories.contains(path),
                actions: actions
            )
        }
        if row.isExpanded, let error = tree.errors[path] {
            note(error, depth: depth, tone: Tone.error)
        }
        if row.entry.isDirectory, case .create(_, path)? = edit?.kind { nameField(depth: depth + 1) }
    }

    private func note(_ text: String, depth: Int, tone: Color?) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
            .padding(.leading, CodeTreeIndent.icon(depth + 1))
            .padding(.trailing, Spacing.regular)
            .padding(.vertical, Spacing.tight)
    }

    private func nameField(depth: Int) -> some View {
        CodeTreeNameField(edit: $edit, depth: depth, onCommit: actions.commit)
    }
}

/// The root row: chevron, folder, the folder's name in semibold; on the
/// right the branch, a dot for uncommitted changes and the ahead/behind
/// counters, or nothing without git.
private struct CodeFilesRootRow: View {
    let line: CodeFilesRootLine
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) { label }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(Motion.toggle, value: isHovering)
            .accessibilityLabel(line.accessibilityLabel)
            .accessibilityValue(CodeFilesRootLine.accessibilityValue(expanded: isExpanded))
    }

    private var label: some View {
        HStack(spacing: Spacing.small) {
            CodeTreeChevron(isExpanded: isExpanded)
            Image(systemName: "folder.fill")
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: IconSize.header)
            Text(line.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line.path)
            Spacer(minLength: Spacing.regular)
            if let branch = line.branch {
                branchCaption(branch)
            }
        }
        .padding(.leading, CodeTreeIndent.leading(0))
        .padding(.trailing, Spacing.compact)
        .padding(.vertical, Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isHovering ? Fill.hover : .clear)
        )
        .contentShape(Rectangle())
    }

    private func branchCaption(_ branch: WorkbenchBranchPresentation.ButtonLabel) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.tertiary)
            if branch.style == .detachedHash {
                Text(branch.text).monospaced()
            } else {
                Text(branch.text)
            }
            if line.dirty {
                Circle()
                    .fill(Tone.warning)
                    .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                    .help(CodeFilesRootLine.dirtyHelp)
            }
            if let counters = line.counters {
                Text(counters).monospacedDigit()
            }
            if line.staleError != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(Tone.warning)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(line.branchHelp)
    }
}

/// The in-place name field: Return commits, Esc or leaving it cancels; an
/// error keeps it open under the field.
private struct CodeTreeNameField: View {
    @Binding var edit: CodeTreeEdit?
    let depth: Int
    let onCommit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.small) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: IconSize.header)
                TextField(placeholder, text: Binding(
                    get: { edit?.text ?? "" },
                    set: { edit?.text = $0; edit?.error = nil }
                ))
                .textFieldStyle(.kit)
                .focused($focused)
                .onSubmit(onCommit)
                .onExitCommand { edit = nil }
            }
            if let error = edit?.error {
                Text(error).font(.caption2).foregroundStyle(Tone.error)
            }
        }
        .padding(.leading, CodeTreeIndent.icon(depth))
        .padding(.trailing, Spacing.compact)
        .padding(.vertical, Spacing.tight)
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused, edit?.error == nil, edit?.isCommitting != true { edit = nil }
        }
    }

    private var icon: String {
        if case .create(true, _)? = edit?.kind { return "folder" }
        return "doc"
    }

    private var placeholder: String {
        switch edit?.kind {
        case .create(true, _)?: "Folder name"
        case .create(false, _)?: "File name or path/to/file"
        default: "New name"
        }
    }
}

private struct CodeFileTreeRow: View {
    let row: CodeFileTree.Row
    /// The row's depth under the root row.
    let depth: Int
    let isOpen: Bool
    let root: URL
    let status: GitFileStatus?
    let holdsChanges: Bool
    let actions: CodeFileTreeList.Actions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.small) {
            if row.entry.isDirectory {
                CodeTreeChevron(isExpanded: row.isExpanded)
            } else {
                Color.clear.frame(width: Spacing.cozy)
            }
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: IconSize.header)
            Text(row.entry.name)
                .font(.callout)
                .foregroundStyle(status.map(GitMark.color) ?? .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let status {
                Text(status.letter)
                    .font(.caption2.monospaced())
                    .foregroundStyle(GitMark.color(status))
                    .help(CodeFilesCopy.notCommitted)
            } else if holdsChanges {
                Circle()
                    .fill(Tone.warning)
                    .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                    .help(CodeFilesCopy.holdsChanges)
            }
        }
        .padding(.leading, CodeTreeIndent.leading(depth))
        .padding(.trailing, Spacing.compact)
        .padding(.vertical, Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isOpen ? Fill.selected : isHovering ? Fill.hover : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !row.entry.isDirectory { actions.open(row.entry, false) } }
        .simultaneousGesture(TapGesture().onEnded { actions.open(row.entry, true) })
        .onHover { isHovering = $0 }
        .animation(Motion.toggle, value: isHovering)
        .contextMenu {
            Button(CodeFilesCopy.newFile) { actions.newEntry(row.entry, false) }
            Button(CodeFilesCopy.newFolder) { actions.newEntry(row.entry, true) }
            Divider()
            Button(CodeFilesCopy.rename) { actions.rename(row.entry) }
            Button(CodeFilesCopy.moveToTrash) { actions.trash(row.entry) }
            Divider()
            Button(CodeFilesCopy.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(row.entry.relPath)])
            }
            Button(CodeFilesCopy.copyRelativePath) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.entry.relPath, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(row.entry, true) }
    }
}
