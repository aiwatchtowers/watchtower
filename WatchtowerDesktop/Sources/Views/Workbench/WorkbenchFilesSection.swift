import AppKit
import SwiftUI
import WatchtowerCore

/// The FILES section at the bottom of the sessions panel. Collapsed it is
/// one header row pinned to the panel's bottom edge; open it shows the
/// workbench folder as a tree, resizable by dragging its top edge. A file
/// click opens it in the Files pane (`WorkbenchesViewModel.openFile`); the
/// header's + and each row's menu create, rename and trash entries, the
/// name typed in place in the tree.
struct WorkbenchFilesSection: View {
    static let heightRange: ClosedRange<Double> = 120...700

    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @AppStorage("workbench.files.expanded") private var isExpanded = false
    @AppStorage("workbench.files.height") private var height: Double = 300
    @State private var liveHeight: Double?
    @State private var cursorPushed = false
    @State private var edit: CodeTreeEdit?
    @State private var trashing: CodeFileEntry?
    /// The folder's file count for the Trash confirmation, counted off the
    /// main thread.
    @State private var trashCount: Int?
    @State private var operationError: String?

    var body: some View {
        let files = vm.codeFiles
        let tree = files.tree(for: project)
        VStack(spacing: 0) {
            if isExpanded { resizeHandle } else { Divider() }
            header(tree)
            if isExpanded {
                notices(files)
                CodeFileTreeList(
                    tree: tree,
                    activeFile: files.tabs(for: project).active,
                    git: files.git(for: project),
                    edit: $edit,
                    actions: rowActions(tree)
                )
                .frame(height: liveHeight ?? height)
                // Keyed by the workbench: the panel is not rebuilt when a deep
                // link switches workbenches, and each one counts as shown
                // exactly while this runs.
                .task(id: project.id) {
                    tree.loadIfNeeded()
                    await files.show(project)
                }
            }
        }
        .confirmationDialog(
            "Move “\(trashing?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = trashing { moveToTrash(entry) }
                trashing = nil
            }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text(trashMessage)
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

    private var trashMessage: String {
        guard let entry = trashing else { return "" }
        let saved = "Unsaved edits are saved first, so the Trash keeps them."
        guard entry.isDirectory else { return "You can put it back from the Trash. Its tab closes. \(saved)" }
        let count = trashCount.map { "It holds \($0) file\($0 == 1 ? "" : "s"). " } ?? ""
        return "\(count)You can put it back from the Trash. Tabs of files in it close. \(saved)"
    }

    private func confirmTrash(_ entry: CodeFileEntry) {
        trashCount = nil
        trashing = entry
        guard entry.isDirectory else { return }
        let url = project.folderURL.appendingPathComponent(entry.relPath)
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
                    Text("FILES").sidebarSectionLabel()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse files" : "Expand files")
            if isExpanded {
                Menu {
                    Button("New File…") { startCreate(folder: false, in: "", tree: tree) }
                    Button("New Folder…") { startCreate(folder: true, in: "", tree: tree) }
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
        if let error = files.watchErrors[project.id] {
            Text(error).font(.caption2).foregroundStyle(.orange).padding(.horizontal, 12)
        }
        if let error = files.gitErrors[project.id] {
            Text("Git status unavailable — the marks may be out of date.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .help(error)
        }
    }

    private func rowActions(_ tree: CodeFileTree) -> CodeFileTreeList.Actions {
        CodeFileTreeList.Actions(
            open: { entry, preview in
                if entry.isDirectory {
                    tree.toggle(entry.relPath)
                } else {
                    Task { await vm.openFile(entry.relPath, project: project, preview: preview) }
                }
            },
            newEntry: { entry, folder in
                startCreate(folder: folder, in: entry.isDirectory ? entry.relPath : CodeFilesCenter.parent(entry.relPath), tree: tree)
            },
            rename: { entry in edit = CodeTreeEdit(kind: .rename(entry.relPath), text: entry.name) },
            trash: { confirmTrash($0) },
            commit: commit,
            root: project.folderURL
        )
    }

    private func startCreate(folder: Bool, in directory: String, tree: CodeFileTree) {
        isExpanded = true
        tree.expand(directory)
        edit = CodeTreeEdit(kind: .create(folder: folder, in: directory), text: "")
    }

    /// Return in the name field. A rename in flight ignores another Return,
    /// and its result only touches the field it started from.
    private func commit() {
        guard var current = edit, !current.isCommitting else { return }
        let files = vm.codeFiles
        switch current.kind {
        case let .create(folder, directory):
            do {
                if folder {
                    try files.createFolder(current.text, in: directory, project: project)
                } else {
                    try files.createFile(current.text, in: directory, project: project)
                    vm.showFilesPane(projectID: project.id)
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
                    try await files.rename(path, to: text, project: project)
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

    private func moveToTrash(_ entry: CodeFileEntry) {
        Task {
            do {
                try await vm.codeFiles.moveToTrash(entry.relPath, project: project)
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
            .padding(.bottom, 6)
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
