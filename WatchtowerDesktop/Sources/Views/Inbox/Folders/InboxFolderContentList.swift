import SwiftUI
import WatchtowerCore

/// The Inbox's second column: the selected folder's entries, newest change
/// first, with unread dots and the "updated …" lines, or the folder's empty
/// state (root, owner folder, Needs approval).
struct InboxFolderContentList: View {
    let content: InboxFolderListContent
    /// A row picked by click or the arrow keys; nil when Escape clears it.
    var onSelect: (String?) -> Void = { _ in }
    /// The empty root's and an empty owner folder's **New Artifact…**.
    var onNewArtifact: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let readError = content.readError {
                InboxReadErrorLine(message: readError)
            }
            if content.rows.isEmpty {
                FeatureEmptyState(copy: content.emptyCopy, readiness: nil, syncLine: nil, turnOnError: nil,
                                  isTurningOn: false) { _ in onNewArtifact() }
                    .padding(.top, Spacing.wide)
                    .frame(maxWidth: .infinity)
            } else {
                // A List, as today's Inbox list (`InboxSplitView`): arrow keys
                // move the selection and VoiceOver reads the rows as a list.
                List(selection: Binding(get: { content.selection }, set: { onSelect($0) })) {
                    Text(content.folderTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                    ForEach(content.rows) { row in
                        InboxFolderListRowView(row: row)
                            .tag(Optional(row.id))
                            .listRowSeparator(.hidden)
                    }
                }
                .clearPlainList()
                .onExitCommand { onSelect(nil) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One list row: the unread dot, the title with its summary, the "updated …"
/// line under it.
struct InboxFolderListRowView: View {
    let row: InboxFolderListRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Circle()
                .fill(row.unread ? Color.accentColor : .clear)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                .accessibilityHidden(!row.unread)
                .accessibilityLabel("Unread")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                    Text(row.title)
                        .font(.callout.weight(row.unread ? .semibold : .regular))
                        .lineLimit(1)
                    if !row.summary.isEmpty {
                        Text("· \(row.summary)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.small)
        .accessibilityElement(children: .combine)
    }
}

/// Today's strip-wide read error line (`ActionStripViewModel.lastError`),
/// kept above the previous list when a folder read fails.
struct InboxReadErrorLine: View {
    let message: String

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .background(Tone.warning.opacity(ChipTint.fillOpacity))
    }
}
