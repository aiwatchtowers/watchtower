import SwiftUI
import WatchtowerCore

/// A folder of the Inbox menu (spec "The model" → Folders): the root, Needs
/// approval, or one of the owner's.
enum InboxFolderKind: String, Equatable, Sendable {
    case root, approvals, owner
}

/// One row of the folder menu, in tree order. `depth` is 0 for the root;
/// a row's children are the rows right after it with a greater depth.
struct InboxFolderRow: Identifiable, Equatable {
    let id: Int64
    let kind: InboxFolderKind
    let title: String
    /// An SF Symbol of the allowlist; empty draws `folder`.
    let icon: String
    let depth: Int
    /// The folder's own count (not its children's); 0 draws none.
    let count: Int
    var hidden = false
    var isExpanded = true

    var systemImage: String {
        switch kind {
        case .root: "tray"
        case .approvals: "checkmark.circle"
        case .owner: icon.isEmpty ? "folder" : icon
        }
    }
}

/// The one line under the menu: a lost revision race reloaded the tree, or
/// the CLI is missing and every edit is off.
enum InboxFolderMenuNote: Equatable {
    case menuChanged, cliUnavailable

    var text: String {
        switch self {
        case .menuChanged: "The menu changed — reloaded. Drag again if needed."
        case .cliUnavailable: "The watchtower CLI isn't available"
        }
    }
}

/// Where a drag would drop: above `targetID` among its siblings, or into it
/// as its last child. A refused drop has none.
struct InboxFolderDrop: Equatable {
    enum Placement: Equatable { case before, into }
    let targetID: Int64
    let placement: Placement
}

/// The inline Delete… confirmation under a folder row: what moves to the
/// root.
struct InboxFolderDeleteSummary: Equatable {
    let folderID: Int64
    let title: String
    let folders: Int
    let automations: Int
    let artifacts: Int

    var text: String {
        let parts = [Self.count(folders, "folder"), Self.count(automations, "automation"),
                     Self.count(artifacts, "artifact")].compactMap { $0 }
        guard !parts.isEmpty else { return "Delete “\(title)”? It is empty." }
        let list = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "Delete “\(title)”? Its \(list) move to Inbox."
    }

    private static func count(_ value: Int, _ noun: String) -> String? {
        value == 0 ? nil : "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// The inline title field of New Folder (under `parentID`) or Rename (of
/// `renamingID`), with a refused write's message under it.
struct InboxFolderDraft: Equatable {
    var parentID: Int64?
    var renamingID: Int64?
    var title: String
    /// The CLI's message without "Error: "; the field stays open.
    var error: String?
}

/// Everything the menu draws, as plain values (plan Task 1): Task 11's
/// `InboxFolderMenuModel` builds it from the folder read and its writes.
struct InboxFolderMenuContent: Equatable {
    var rows: [InboxFolderRow]
    var selection: Int64?
    var note: InboxFolderMenuNote?
    var dropIndicator: InboxFolderDrop?
    var deleteConfirmation: InboxFolderDeleteSummary?
    var newFolderDraft: InboxFolderDraft?
    /// A dropped folder sits dimmed in its new place while the move runs;
    /// the menu is read-only meanwhile.
    var pendingMoveID: Int64?
    /// The root's ⋯ Show Hidden Folders is on.
    var showsHidden = false
    /// Icon ▸'s allowlist (`InboxFolderIcons`).
    var icons: [String] = []

    /// No edit, drag or menu write: the CLI is missing or a move runs.
    var isReadOnly: Bool { note == .cliUnavailable || pendingMoveID != nil }

    /// The rows drawn: a collapsed folder's descendants are left out.
    var visibleRows: [InboxFolderRow] {
        var collapsedDepth: Int?
        return rows.filter { row in
            if let depth = collapsedDepth {
                if row.depth > depth { return false }
                collapsedDepth = nil
            }
            if !row.isExpanded { collapsedDepth = row.depth }
            return true
        }
    }

    func hasChildren(_ row: InboxFolderRow) -> Bool {
        guard let index = rows.firstIndex(of: row), rows.indices.contains(index + 1) else { return false }
        return rows[index + 1].depth > row.depth
    }
}

/// What a press in the menu asks for.
enum InboxFolderMenuAction: Equatable {
    case select(Int64)
    case toggleExpanded(Int64)
    case newFolder
    case newArtifact
    case draftChanged(String)
    case commitDraft
    case cancelDraft
    case confirmDelete(Int64)
    case cancelDelete
    case menu(folderID: Int64, InboxMenuCommand)
}

/// The Inbox's first column (spec "The Inbox screen" 1): the root and its
/// count, Needs approval, the owner folders as a disclosure tree with icons
/// and counts, **+ New Folder** and **+ New Artifact…** at the bottom, and
/// the state lines (reload, CLI unavailable, a refused write). No model and
/// no CLI: values in, presses out.
struct InboxFolderMenu: View {
    let content: InboxFolderMenuContent
    var onAction: (InboxFolderMenuAction) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(content.visibleRows) { row in
                if content.dropIndicator == InboxFolderDrop(targetID: row.id, placement: .before) {
                    dropLine(depth: row.depth)
                }
                folderRow(row)
                if let draft = content.newFolderDraft, draft.renamingID == nil, let parent = draftParent(draft),
                   lastVisibleDescendant(of: parent) == row.id {
                    draftField(draft, depth: parent.depth + 1)
                }
                if let summary = content.deleteConfirmation, summary.folderID == row.id {
                    deleteConfirmation(summary, depth: row.depth)
                }
            }
            footer
        }
        .controlSize(.small)
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Rows

    @ViewBuilder
    private func folderRow(_ row: InboxFolderRow) -> some View {
        if let draft = content.newFolderDraft, draft.renamingID == row.id {
            draftField(draft, depth: row.depth)
        } else {
            let pending = content.pendingMoveID == row.id
            HStack(spacing: Spacing.compact) {
                disclosure(row)
                Image(systemName: row.systemImage)
                    .foregroundStyle(row.kind == .owner ? Color.secondary : Color.accentColor)
                    .frame(width: IconSize.header)
                Text(row.title)
                    .font(.callout.weight(row.kind == .root ? .semibold : .regular))
                    .lineLimit(1)
                if row.hidden {
                    Text("Hidden").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.small)
                if pending {
                    ProgressView().controlSize(.mini)
                } else if row.count >= 1 {
                    Text("\(row.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Spacing.medium * CGFloat(row.depth))
            .kitRow(isSelected: content.selection == row.id)
            .overlay {
                if content.dropIndicator == InboxFolderDrop(targetID: row.id, placement: .into) {
                    RoundedRectangle(cornerRadius: Radius.row)
                        .strokeBorder(Color.accentColor, lineWidth: Stroke.selection)
                }
            }
            .opacity(row.hidden || pending ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { onAction(.select(row.id)) }
            .contextMenu {
                if !content.isReadOnly {
                    InboxMenuItems(entries: menuEntries(row)) { onAction(.menu(folderID: row.id, $0)) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(content.selection == row.id ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// A chevron for a folder with children; the same width otherwise, so
    /// titles line up.
    @ViewBuilder
    private func disclosure(_ row: InboxFolderRow) -> some View {
        if row.kind == .owner, content.hasChildren(row) {
            Button { onAction(.toggleExpanded(row.id)) } label: {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.kitQuiet)
            .frame(width: IconSize.chevron)
            .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: IconSize.chevron, height: 1)
        }
    }

    private func menuEntries(_ row: InboxFolderRow) -> [InboxMenuEntry] {
        switch row.kind {
        case .root: InboxArtifactMenuContent.rootEntries(showingHidden: content.showsHidden)
        case .approvals: InboxArtifactMenuContent.approvalsEntries(isEnabled: true)
        case .owner: InboxArtifactMenuContent.folderEntries(row, icons: content.icons)
        }
    }

    /// The folder a New Folder field goes into: its parent, or the root.
    private func draftParent(_ draft: InboxFolderDraft) -> InboxFolderRow? {
        let rows = content.visibleRows
        return rows.first { $0.id == draft.parentID } ?? rows.first { $0.kind == .root }
    }

    /// The last visible row under `row` (itself when it has none): where a
    /// New Folder Inside field goes.
    private func lastVisibleDescendant(of row: InboxFolderRow) -> Int64 {
        let rows = content.visibleRows
        guard let index = rows.firstIndex(of: row) else { return row.id }
        var last = row.id
        for next in rows[(index + 1)...] {
            guard next.depth > row.depth else { break }
            last = next.id
        }
        return last
    }

    // MARK: - Inline states

    private func dropLine(depth: Int) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: Stroke.selection * 2)
            .padding(.leading, Spacing.medium * CGFloat(depth) + Spacing.regular)
            .accessibilityHidden(true)
    }

    private func draftField(_ draft: InboxFolderDraft, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.compact) {
                Color.clear.frame(width: IconSize.chevron, height: 1)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: IconSize.header)
                TextField("Folder name", text: Binding(get: { draft.title }, set: { onAction(.draftChanged($0)) }))
                    .textFieldStyle(.kit)
                    .onSubmit { onAction(.commitDraft) }
                    .onExitCommand { onAction(.cancelDraft) }
            }
            if let error = draft.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, Spacing.medium * CGFloat(depth))
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.tight)
    }

    private func deleteConfirmation(_ summary: InboxFolderDeleteSummary, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(summary.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Button("Cancel") { onAction(.cancelDelete) }
                    .buttonStyle(.kitSecondary)
                Button("Delete") { onAction(.confirmDelete(summary.folderID)) }
                    .buttonStyle(.kitDestructive)
                    .disabled(content.isReadOnly)
            }
        }
        .padding(Spacing.regular)
        .card()
        .padding(.leading, Spacing.medium * CGFloat(depth + 1))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Group {
                Button { onAction(.newFolder) } label: { Label("New Folder", systemImage: "plus") }
                Button { onAction(.newArtifact) } label: { Label("New Artifact…", systemImage: "plus") }
            }
            .buttonStyle(.kitQuiet)
            .disabled(content.isReadOnly)
            if let note = content.note {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.regular)
                    .padding(.horizontal, Spacing.regular)
            }
        }
        .padding(.top, Spacing.medium)
    }
}
