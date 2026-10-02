import AppKit
import SwiftUI
import WatchtowerCore

/// POC (code viewer): the FILES section at the bottom of the sessions panel.
/// Collapsed it is one header row pinned to the panel's bottom edge; open it
/// shows the workbench folder as a tree, resizable by dragging its top edge.
/// A file click opens it in the workspace (`WorkbenchesViewModel.openFile`).
struct WorkbenchFilesSection: View {
    static let heightRange: ClosedRange<Double> = 120...700

    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @AppStorage("workbench.files.expanded") private var isExpanded = false
    @AppStorage("workbench.files.height") private var height: Double = 300
    @State private var liveHeight: Double?
    @State private var cursorPushed = false

    var body: some View {
        let tree = vm.codeFiles.tree(for: project)
        VStack(spacing: 0) {
            if isExpanded { resizeHandle } else { Divider() }
            header(tree)
            if isExpanded {
                CodeFileTreeList(
                    tree: tree, activeFile: vm.codeFiles.tabs(for: project).active, git: vm.codeFiles.git(for: project)
                ) { entry, preview in
                    vm.openFile(entry.relPath, project: project, preview: preview)
                }
                .frame(height: liveHeight ?? height)
                .onAppear { tree.loadIfNeeded() }
            }
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

/// The tree's visible rows: folders toggle on click; a file opens in a
/// preview tab on a single click and in a kept tab on a double click.
/// Uncommitted files carry their git mark, and a folder holding one a dot.
struct CodeFileTreeList: View {
    let tree: CodeFileTree
    let activeFile: String?
    let git: GitStatusSnapshot
    let onOpen: (CodeFileEntry, _ preview: Bool) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = tree.errors[""] {
                    Text(error).font(.caption).foregroundStyle(.red).padding(8)
                }
                ForEach(tree.rows, id: \.entry.relPath) { row in
                    let path = row.entry.relPath
                    CodeFileTreeRow(
                        row: row, isOpen: activeFile == path, root: tree.root,
                        status: git.files[path], holdsChanges: row.entry.isDirectory && git.dirtyDirectories.contains(path),
                        action: {
                            if row.entry.isDirectory {
                                tree.toggle(path)
                            } else {
                                onOpen(row.entry, true)
                            }
                        },
                        keep: { if !row.entry.isDirectory { onOpen(row.entry, false) } }
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }
}

private struct CodeFileTreeRow: View {
    let row: CodeFileTree.Row
    let isOpen: Bool
    let root: URL
    let status: GitFileStatus?
    let holdsChanges: Bool
    let action: () -> Void
    let keep: () -> Void
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
        .onTapGesture(count: 2, perform: keep)
        .simultaneousGesture(TapGesture().onEnded(action))
        .onHover { isHovering = $0 }
        .contextMenu {
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
        .accessibilityAction { action() }
    }

    private var background: Color {
        if isOpen { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.05) : .clear
    }
}
