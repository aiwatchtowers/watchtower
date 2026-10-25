import SwiftUI
import WatchtowerCore

/// The changed files as a folder tree (#960), rendered as rows of the
/// enclosing `List`. Folders start expanded; the collapsed set lives here and
/// resets with the round, and the selected file's folders open. A folder row
/// shows how many of its files are not yet viewed and the open comments under it.
struct ReviewFileTreeView: View {
    let model: ReviewChangesModel
    let files: [ReviewDiffFile]

    @State private var collapsed: Set<String> = []

    var body: some View {
        let byPath = files.reduce(into: [String: ReviewDiffFile]()) { $0[$1.path] = $1 }
        ForEach(rows) { row in
            switch row.node {
            case let .folder(name, path, children):
                folderRow(name: name, path: path, children: children, depth: row.depth)
            case let .file(path):
                if let file = byPath[path] {
                    ReviewFileListView.row(file, model: model, title: Self.fileName(path), depth: row.depth)
                }
            }
        }
        .onChange(of: model.round?.id) { collapsed = [] }
        .onChange(of: model.selectedPath) { _, path in
            if let path { collapsed = ReviewFileTree.revealing(path, in: collapsed) }
        }
    }

    private struct Row: Identifiable {
        let node: ReviewFileTree.Node
        let depth: Int
        var id: String {
            switch node {
            case let .folder(_, path, _): "d:" + path
            case let .file(path): "f:" + path
            }
        }
    }

    /// The visible rows, depth first; a collapsed folder hides its children.
    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ nodes: [ReviewFileTree.Node], depth: Int) {
            for node in nodes {
                out.append(Row(node: node, depth: depth))
                if case let .folder(_, path, children) = node, !collapsed.contains(path) {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(ReviewFileTree.build(files.map(\.path)), depth: 0)
        return out
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func folderRow(name: String, path: String, children: [ReviewFileTree.Node], depth: Int) -> some View {
        let isOpen = !collapsed.contains(path)
        let counts = ReviewFileTree.counts(of: children, isViewed: model.isViewed, comments: model.comments)
        let unviewed = counts.unviewed
        let comments = counts.openComments
        return Button {
            if isOpen { collapsed.insert(path) } else { collapsed.remove(path) }
        } label: {
            HStack(spacing: Spacing.compact) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if comments > 0 {
                    Text("\(comments)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Spacing.compact)
                        .background(Fill.on, in: Capsule())
                        .accessibilityLabel("\(comments) comment\(comments == 1 ? "" : "s")")
                }
                Text(unviewed == 0 ? "all viewed" : "\(unviewed) unviewed")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * Spacing.regular)
        .padding(.vertical, Spacing.tight)
        .listRowInsets(EdgeInsets(top: Spacing.tight, leading: Spacing.regular, bottom: Spacing.tight, trailing: Spacing.regular))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel("\(name), \(isOpen ? "expanded" : "collapsed"), \(unviewed) unviewed")
    }
}
