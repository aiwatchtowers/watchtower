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
            CodeFileTreeRows(
                tree: tree,
                activeFile: files.tabs(for: item.root).active,
                git: files.git(for: item.root),
                edit: editBinding(item.root),
                actions: rowActions(tree, root: item.root)
            )
            .padding(.leading, Spacing.medium)
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
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(root.filesCaption).sidebarSectionLabel()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(root.isMain ? "" : "The worktree the session on screen works in:\n\(root.folder.path)")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse files" : "Expand files")
            if isExpanded {
                Button(action: putOnBench) {
                    Image(systemName: Copy.putOnBenchIcon)
                }
                .buttonStyle(.borderless)
                .disabled(vm.puttingOnBench.contains(project.id))
                .help(Copy.tooltip)
                .accessibilityLabel(Copy.tooltip)
                Menu {
                    Button("New File…") { startCreate(folder: false, in: "", tree: tree, root: root) }
                    Button("New Folder…") { startCreate(folder: true, in: "", tree: tree, root: root) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New file or folder")
                .accessibilityLabel("New file or folder")
                Button {
                    tree.collapseAll()
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.borderless)
                .help("Collapse all folders")
                .accessibilityLabel("Collapse all folders")
                Button {
                    tree.reloadAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload the tree")
                .accessibilityLabel("Reload the tree")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            Text(error).font(.caption2).foregroundStyle(.orange).padding(.horizontal, 12)
        }
        if let error = files.gitErrors[root] {
            Text("Git status unavailable — the marks may be out of date.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
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
            .padding(.vertical, 3)
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

/// The tree's visible rows: folders toggle on click; a file opens in a
/// preview tab on a single click and in a kept tab on a double click.
/// Uncommitted files carry their git mark, and a folder holding one a dot.
/// A folder that could not be read says so under its row.
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
    let activeFile: String?
    let git: GitStatusSnapshot
    @Binding var edit: CodeTreeEdit?
    let actions: Actions

    var body: some View {
        ScrollView {
            CodeFileTreeRows(tree: tree, activeFile: activeFile, git: git, edit: $edit, actions: actions)
                .padding(.bottom, Spacing.compact)
        }
    }
}

/// A tree's rows without a scroll view of their own: the one-folder list's
/// content, and each open root's under its row on a several-folder bench.
struct CodeFileTreeRows: View {
    let tree: CodeFileTree
    let activeFile: String?
    let git: GitStatusSnapshot
    @Binding var edit: CodeTreeEdit?
    let actions: CodeFileTreeList.Actions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
                if let error = tree.errors[""] {
                    Text(error).font(.caption).foregroundStyle(.red).padding(8)
                }
                if case .create(_, "")? = edit?.kind { nameField(depth: 0) }
                ForEach(tree.rows, id: \.entry.relPath) { row in
                    let path = row.entry.relPath
                    if case .rename(path)? = edit?.kind {
                        nameField(depth: row.depth)
                    } else {
                        CodeFileTreeRow(
                            row: row, isOpen: activeFile == path, root: actions.root,
                            status: git.files[path], holdsChanges: row.entry.isDirectory && git.dirtyDirectories.contains(path),
                            actions: actions
                        )
                    }
                    if row.isExpanded, let error = tree.errors[path] {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.leading, 34 + CGFloat(row.depth) * 12)
                    }
                    if row.entry.isDirectory, case .create(_, path)? = edit?.kind { nameField(depth: row.depth + 1) }
                }
        }
    }

    private func nameField(depth: Int) -> some View {
        CodeTreeNameField(edit: $edit, depth: depth, onCommit: actions.commit)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                TextField(placeholder, text: Binding(
                    get: { edit?.text ?? "" },
                    set: { edit?.text = $0; edit?.error = nil }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($focused)
                .onSubmit(onCommit)
                .onExitCommand { edit = nil }
            }
            if let error = edit?.error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.leading, 20 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
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
    let isOpen: Bool
    let root: URL
    let status: GitFileStatus?
    let holdsChanges: Bool
    let actions: CodeFileTreeList.Actions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if row.entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(row.entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 14)
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
                    .help("Not committed")
            } else if holdsChanges {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .help("Holds uncommitted changes")
            }
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !row.entry.isDirectory { actions.open(row.entry, false) } }
        .simultaneousGesture(TapGesture().onEnded { actions.open(row.entry, true) })
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("New File…") { actions.newEntry(row.entry, false) }
            Button("New Folder…") { actions.newEntry(row.entry, true) }
            Divider()
            Button("Rename…") { actions.rename(row.entry) }
            Button("Move to Trash") { actions.trash(row.entry) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(row.entry.relPath)])
            }
            Button("Copy Relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.entry.relPath, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(row.entry, true) }
    }

    private var background: Color {
        if isOpen { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.05) : .clear
    }
}
