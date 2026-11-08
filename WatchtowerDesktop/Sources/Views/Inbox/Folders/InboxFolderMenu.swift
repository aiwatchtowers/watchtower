import SwiftUI
import UniformTypeIdentifiers
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
    /// An owner folder's drag starts, hovers over a drop (nil: over none)
    /// and drops.
    case beginDrag(Int64)
    case dragOver(InboxFolderDrop?)
    case drop(InboxFolderDrop)
}

/// The Inbox's first column (spec "The Inbox screen" 1): the root and its
/// count, Needs approval, the owner folders as a disclosure tree with icons
/// and counts, **+ New Folder** and **+ New Artifact…** at the bottom, and
/// the state lines (reload, CLI unavailable, a refused write). No model and
/// no CLI: values in, presses out.
struct InboxFolderMenu: View {
    let content: InboxFolderMenuContent
    var onAction: (InboxFolderMenuAction) -> Void = { _ in }

    /// New Folder and Rename put the cursor in their field.
    @FocusState private var draftFocused: Bool

    /// The scroll anchor of a New Folder field.
    private static let draftFieldID = "inbox-folder-draft"

    /// The tree scrolls; New Folder, New Artifact… and the state line stay
    /// pinned under it, however many folders there are.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(content.visibleRows) { row in
                            if content.dropIndicator == InboxFolderDrop(targetID: row.id, placement: .before) {
                                dropLine(depth: row.depth)
                            }
                            folderRow(row)
                            if let refusal = content.refusal, refusal.folderID == row.id {
                                refusalLine(refusal.message, depth: row.depth)
                            }
                            if let draft = content.folderDraft, case let .create(parentID) = draft.target,
                               let parent = draftParent(parentID), lastVisibleDescendant(of: parent) == row.id {
                                draftField(draft, depth: parent.depth + 1)
                                    .id(Self.draftFieldID)
                            }
                            if let summary = content.deleteConfirmation, summary.folderID == row.id {
                                deleteConfirmation(summary, depth: row.depth)
                            }
                        }
                    }
                    .padding(Spacing.regular)
                }
                // New Folder from the footer adds its field at the end of a
                // long tree: bring it into view.
                .onChange(of: content.folderDraft?.target) { _, target in
                    guard target != nil else { return }
                    withAnimation(Motion.panel) { proxy.scrollTo(Self.draftFieldID) }
                }
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
        if let draft = content.folderDraft, draft.target == .rename(row.id) {
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
            .modifier(FolderDragModifier(row: row, readOnly: content.isReadOnly, onAction: onAction))
            .contextMenu {
                InboxMenuItems(entries: menuEntries(row), readOnly: content.isReadOnly) {
                    onAction(.menu(folderID: row.id, $0))
                }
            }
            // One VoiceOver element per folder: its default action selects
            // it, and its ⋯ entries (and Expand/Collapse) are named actions,
            // so the options never depend on hover.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onAction(.select(row.id)) }
            .accessibilityActions {
                if row.kind == .owner, content.hasChildren(row) {
                    Button(row.isExpanded ? "Collapse" : "Expand") { onAction(.toggleExpanded(row.id)) }
                }
                ForEach(Array(accessibilityEntries(row).enumerated()), id: \.offset) { _, entry in
                    Button(entry.title) {
                        if let command = entry.command { onAction(.menu(folderID: row.id, command)) }
                    }
                }
            }
        }
    }

    /// The row's ⋯ entries flattened for VoiceOver ("Icon: Flag"), the
    /// writes left out while the menu is read-only.
    private func accessibilityEntries(_ row: InboxFolderRow) -> [InboxMenuEntry] {
        menuEntries(row).flatMap { entry in
            entry.children.isEmpty ? [entry] : entry.children.map { child in
                InboxMenuEntry(title: "\(entry.title): \(child.title)", command: child.command)
            }
        }
        .filter { $0.command != nil && (!content.isReadOnly || $0.command?.isRead == true) }
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
        case .approvals: InboxArtifactMenuContent.approvalsEntries(isEnabled: content.approvalsEnabled)
        case .owner: InboxArtifactMenuContent.folderEntries(row, icons: content.icons)
        }
    }

    /// The folder a New Folder field goes into: its parent, or the root.
    private func draftParent(_ parentID: Int64?) -> InboxFolderRow? {
        let rows = content.visibleRows
        return rows.first { $0.id == parentID } ?? rows.first { $0.kind == .root }
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
                    .focused($draftFocused)
                    .onAppear { draftFocused = true }
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
            if let refusal = content.refusal,
               !content.visibleRows.contains(where: { $0.id == refusal.folderID }) {
                refusalLine(refusal.message, depth: 0)
            }
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

/// A refused write's message, under the row it was about.
private func refusalLine(_ message: String, depth: Int) -> some View {
    Text(message)
        .font(.caption)
        .foregroundStyle(Tone.error)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, Spacing.medium * CGFloat(depth) + Spacing.regular)
        .padding(.horizontal, Spacing.regular)
}

/// Drag and drop on a folder row (spec "Drag"): an owner folder drags; every
/// row takes a drop, before it (its top band) or into it. Whether a drop is
/// allowed is the model's call: a refused one draws no indicator.
private struct FolderDragModifier: ViewModifier {
    let row: InboxFolderRow
    let readOnly: Bool
    let onAction: (InboxFolderMenuAction) -> Void

    func body(content: Content) -> some View {
        if readOnly {
            content
        } else if row.kind == .owner {
            content
                .onDrag {
                    onAction(.beginDrag(row.id))
                    return NSItemProvider(object: String(row.id) as NSString)
                }
                .onDrop(of: [.text], delegate: FolderDropDelegate(rowID: row.id, onAction: onAction))
        } else {
            content.onDrop(of: [.text], delegate: FolderDropDelegate(rowID: row.id, onAction: onAction))
        }
    }
}

private struct FolderDropDelegate: DropDelegate {
    let rowID: Int64
    let onAction: (InboxFolderMenuAction) -> Void

    /// The top of a row places the folder before it; the rest, into it.
    private static let beforeBand: CGFloat = 8

    private func drop(_ info: DropInfo) -> InboxFolderDrop {
        InboxFolderDrop(targetID: rowID, placement: info.location.y < Self.beforeBand ? .before : .into)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onAction(.dragOver(drop(info)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onAction(.dragOver(nil))
    }

    func performDrop(info: DropInfo) -> Bool {
        onAction(.drop(drop(info)))
        return true
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
