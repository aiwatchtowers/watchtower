import SwiftUI
import WatchtowerCore

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

    /// The tree scrolls; New Folder, New Artifact… and the state line stay
    /// pinned under it, however many folders there are.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(content.visibleRows) { row in
                        if content.dropIndicator == InboxFolderDrop(targetID: row.id, placement: .before) {
                            dropLine(depth: row.depth)
                        }
                        folderRow(row)
                        if let draft = content.newFolderDraft, draft.renamingID == nil,
                           let parent = draftParent(draft), lastVisibleDescendant(of: parent) == row.id {
                            draftField(draft, depth: parent.depth + 1)
                        }
                        if let summary = content.deleteConfirmation, summary.folderID == row.id {
                            deleteConfirmation(summary, depth: row.depth)
                        }
                    }
                }
                .padding(Spacing.regular)
            }
            footer
                .padding(.horizontal, Spacing.regular)
                .padding(.bottom, Spacing.regular)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Rows

    @ViewBuilder
    private func folderRow(_ row: InboxFolderRow) -> some View {
        if let draft = content.newFolderDraft, draft.renamingID == row.id {
            draftField(draft, depth: row.depth)
        } else {
            let pending = content.pendingMoveID == row.id
            let selected = content.selection == row.id
            HoverReader { hovered in
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
                    } else {
                        if row.count >= 1 {
                            Text("\(row.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        // The folder's ⋯ (spec: "also its context menu"): on
                        // the row under the pointer and on the selected one.
                        if hovered || selected {
                            InboxMoreMenu(entries: menuEntries(row), help: "\(row.title) Options",
                                          readOnly: content.isReadOnly) { onAction(.menu(folderID: row.id, $0)) }
                        }
                    }
                }
            }
            .padding(.leading, Spacing.medium * CGFloat(row.depth))
            .kitRow(isSelected: selected)
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
                InboxMenuItems(entries: menuEntries(row), readOnly: content.isReadOnly) {
                    onAction(.menu(folderID: row.id, $0))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
        .padding(.top, Spacing.regular)
    }
}

/// Hands its content whether the pointer is over it (a row's ⋯ shows on
/// hover).
private struct HoverReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered).onHover { hovered = $0 }
    }
}
