import SwiftUI
import WatchtowerCore

/// One entry of a folder's list (spec "The Inbox screen" 2): an automation
/// artifact, a legacy entry over today's panes (Morning brief, Track my
/// threads, Idea finder, Messages), or a native approval card in Needs
/// approval.
struct InboxFolderEntry: Identifiable, Equatable {
    enum Kind: Equatable { case artifact, legacy, approval }

    let id: String
    let kind: Kind
    let title: String
    /// "4 waiting", "today", "2 unread"; empty draws none.
    var summary = ""
    /// "updated 6 min ago · after every sync", "run #12 · 2 h ago".
    var detail = ""
    var unread = false
}

/// The folder's list as plain values (plan Task 1); Task 12 reads it from
/// `inbox_artifact_folders` and the legacy feeds.
struct InboxFolderListContent: Equatable {
    let folderKind: InboxFolderKind
    let folderTitle: String
    var entries: [InboxFolderEntry] = []
    var selection: String?
    /// A failed folder read: the previous list stays under today's strip
    /// error line.
    var readError: String?
}

/// The Inbox's second column: the selected folder's entries, newest change
/// first, with unread dots and the "updated …" lines, or the folder's empty
/// state (root, owner folder, Needs approval).
struct InboxFolderContentList: View {
    let content: InboxFolderListContent
    var onSelect: (String) -> Void = { _ in }
    /// The empty root's and an empty owner folder's **New Artifact…**.
    var onNewArtifact: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let readError = content.readError {
                InboxReadErrorLine(message: readError)
            }
            if content.entries.isEmpty {
                FeatureEmptyState(copy: Self.emptyCopy(content), readiness: nil, syncLine: nil, turnOnError: nil,
                                  isTurningOn: false) { _ in onNewArtifact() }
                    .padding(.top, Spacing.wide)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(content.folderTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.regular)
                            .padding(.bottom, Spacing.small)
                        ForEach(content.entries) { entry in
                            InboxFolderEntryRow(entry: entry, isSelected: content.selection == entry.id)
                                .onTapGesture { onSelect(entry.id) }
                        }
                    }
                    .padding(Spacing.regular)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The empty folder's words (spec "The Inbox screen" → States). Task 12
    /// moves them into `EmptyStateCopyTable` under `inbox`, `inboxFolder`
    /// and `inboxApprovals`.
    static func emptyCopy(_ content: InboxFolderListContent) -> EmptyStateCopy {
        switch content.folderKind {
        case .root:
            EmptyStateCopy(icon: "tray", title: "Your Inbox is empty",
                           landsHere: "Automations put what they make here.",
                           feature: nil, primaryAction: .tabAction(label: "New Artifact…"))
        case .owner:
            EmptyStateCopy(icon: "folder", title: "Nothing in \(content.folderTitle) yet",
                           landsHere: "Move an automation here from its ⋯ menu, or make a new one.",
                           feature: nil, primaryAction: .tabAction(label: "New Artifact…"))
        case .approvals:
            EmptyStateCopy(icon: "checkmark.circle", title: "Nothing waits for your approval",
                           landsHere: "",
                           feature: nil, primaryAction: nil)
        }
    }
}

/// One list row: the unread dot, the title with its summary, the "updated …"
/// line under it.
struct InboxFolderEntryRow: View {
    let entry: InboxFolderEntry
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Circle()
                .fill(entry.unread ? Color.accentColor : .clear)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                .accessibilityHidden(!entry.unread)
                .accessibilityLabel("Unread")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                    Text(entry.title)
                        .font(.callout.weight(entry.unread ? .semibold : .regular))
                        .lineLimit(1)
                    if !entry.summary.isEmpty {
                        Text("· \(entry.summary)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .kitRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
