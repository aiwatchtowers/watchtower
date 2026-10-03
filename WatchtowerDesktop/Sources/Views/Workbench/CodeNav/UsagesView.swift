import AppKit
import SwiftUI
import WatchtowerCore

/// The inspector's Usages tab (spec §8.3): "Usages — name · N", then one
/// disclosure group per file in the order the search found them, rows
/// `line  text` with the name bold. A click opens the file at the line.
struct UsagesView: View {
    let usages: CodeUsagesCenter
    let project: Workbench

    var body: some View {
        if let model = usages.usages(for: project.id) {
            VStack(alignment: .leading, spacing: 0) {
                header(model)
                Divider()
                List {
                    ForEach(model.groups) { group in
                        DisclosureGroup(isExpanded: expansion(of: group.path)) {
                            ForEach(group.rows) { row in
                                UsageRowView(row: row) {
                                    Task { await usages.openUsage(row, project: project) }
                                }
                            }
                        } label: {
                            UsageGroupLabel(group: group, folder: project.folderURL)
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else {
            ContentUnavailableView(
                "No usages",
                systemImage: "text.magnifyingglass",
                description: Text("Put the cursor on a name and press ⇧⌘U.")
            )
        }
    }

    private func header(_ model: UsagesModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.header)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if model.status == .searching {
                    ProgressView().controlSize(.small)
                }
            }
            if model.status != .searching, let status = model.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(failed(model) ? Color.red : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func failed(_ model: UsagesModel) -> Bool {
        if case .failed = model.status { return true }
        return false
    }

    /// Read from the center each time, so a group keeps its state while
    /// matches stream in.
    private func expansion(of path: String) -> Binding<Bool> {
        Binding(
            get: { usages.usages(for: project.id)?.isCollapsed(path) == false },
            set: { usages.setCollapsed(!$0, path: path, workbenchID: project.id) }
        )
    }
}

/// A file's group: Finder icon, name, folder, how many usages.
private struct UsageGroupLabel: View {
    let group: UsageGroup
    let folder: URL

    var body: some View {
        let name = (group.path as NSString).lastPathComponent
        let parent = (group.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.appendingPathComponent(group.path).path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(name).font(.callout).lineLimit(1)
            if !parent.isEmpty {
                Text(parent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text("\(group.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(group.path)
        .accessibilityElement(children: .combine)
    }
}

/// `line  text`, the name bold.
private struct UsageRowView: View {
    let row: UsageRow
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.line)")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(.caption, design: .monospaced))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.path):\(row.line)")
        .accessibilityLabel("Line \(row.line): \(row.parts.before)\(row.parts.name)\(row.parts.after)")
    }

    private var text: AttributedString {
        var name = AttributedString(row.parts.name)
        name.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString(row.parts.before) + name + AttributedString(row.parts.after)
    }
}
