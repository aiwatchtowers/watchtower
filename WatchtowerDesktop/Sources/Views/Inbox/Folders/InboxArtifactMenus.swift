import SwiftUI
import WatchtowerCore

/// What a press in one of the Inbox's ⋯ menus asks for (spec "The Inbox
/// screen" → Menus). The views only emit it; Task 14 carries it out through
/// the Automations tab's own verbs and `watchtower inbox folders …`.
enum InboxMenuCommand: Hashable {
    // The artifact ⋯ (and Needs approval's).
    case runNow, editCollects, editLook, schedule, moveTo(folderID: Int64), turnOff, turnOn, runHistory, delete
    // An owner folder's ⋯.
    case rename, icon(String), newFolderInside, hide, show, deleteFolder
    // The root's ⋯.
    case learnedRules, assistantProfile, showHiddenFolders, hideHiddenFolders, newFolder
    // The Idea finder legacy entry's ⋯.
    case findIdeasInPastMessages
}

/// One entry of an Inbox ⋯ menu: a press, or a submenu (`children`) such as
/// **Move to Folder ▸** and **Icon ▸**. `checked` marks the current choice,
/// `indent` a folder's depth inside Move to Folder.
struct InboxMenuEntry: Equatable {
    let title: String
    var command: InboxMenuCommand?
    var destructive = false
    var checked = false
    var indent = 0
    var systemImage: String?
    var children: [Self] = []
}

/// Which entries an artifact's ⋯ offers (spec: a built-in has no Delete…,
/// Needs approval's automation has no Move to Folder, a built-in without
/// Run Now has none). Plain values; Task 14 fills them from the automation.
struct InboxArtifactMenuContent: Equatable {
    var isBuiltin = false
    var offersRunNow = true
    var movable = true
    var isEnabled = true
    /// The folders Move to Folder ▸ offers: every folder but Needs approval.
    var folders: [InboxFolderRow] = []
    /// The folder the automation's route points at; the root when nil.
    var currentFolderID: Int64?

    var entries: [InboxMenuEntry] {
        var entries: [InboxMenuEntry] = []
        if offersRunNow { entries.append(InboxMenuEntry(title: "Run Now", command: .runNow)) }
        entries += [
            InboxMenuEntry(title: "Edit What It Collects…", command: .editCollects),
            InboxMenuEntry(title: "Edit the Look…", command: .editLook),
            InboxMenuEntry(title: "Schedule…", command: .schedule)
        ]
        if movable {
            entries.append(InboxMenuEntry(title: "Move to Folder", children: Self.moveTargets(
                folders, current: currentFolderID)))
        }
        entries.append(isEnabled ? InboxMenuEntry(title: "Turn Off", command: .turnOff)
                                 : InboxMenuEntry(title: "Turn On", command: .turnOn))
        entries.append(InboxMenuEntry(title: "Run History", command: .runHistory))
        if !isBuiltin { entries.append(InboxMenuEntry(title: "Delete…", command: .delete, destructive: true)) }
        return entries
    }

    /// The tree, the current folder checked (the root when no route), Needs
    /// approval left out: it is never a target.
    static func moveTargets(_ folders: [InboxFolderRow], current: Int64?) -> [InboxMenuEntry] {
        let rootID = folders.first { $0.kind == .root }?.id
        return folders.filter { $0.kind != .approvals }.map { folder in
            InboxMenuEntry(title: folder.title, command: .moveTo(folderID: folder.id),
                           checked: folder.id == (current ?? rootID), indent: folder.depth)
        }
    }

    /// An owner folder's ⋯: Rename…, Icon ▸ (the allowlist), New Folder
    /// Inside, Hide or Show, Delete….
    static func folderEntries(_ folder: InboxFolderRow, icons: [String]) -> [InboxMenuEntry] {
        [
            InboxMenuEntry(title: "Rename…", command: .rename),
            InboxMenuEntry(title: "Icon", children: icons.map { icon in
                InboxMenuEntry(title: icon, command: .icon(icon), checked: icon == folder.icon, systemImage: icon)
            }),
            InboxMenuEntry(title: "New Folder Inside", command: .newFolderInside),
            folder.hidden ? InboxMenuEntry(title: "Show", command: .show) : InboxMenuEntry(title: "Hide", command: .hide),
            InboxMenuEntry(title: "Delete…", command: .deleteFolder, destructive: true)
        ]
    }

    /// The root's ⋯: the two panes the old header ⋯ held, Show (or Hide)
    /// Hidden Folders, New Folder.
    static func rootEntries(showingHidden: Bool) -> [InboxMenuEntry] {
        [
            InboxMenuEntry(title: "Learned Rules", command: .learnedRules),
            InboxMenuEntry(title: "Assistant Profile", command: .assistantProfile),
            showingHidden ? InboxMenuEntry(title: "Hide Hidden Folders", command: .hideHiddenFolders)
                          : InboxMenuEntry(title: "Show Hidden Folders", command: .showHiddenFolders),
            InboxMenuEntry(title: "New Folder", command: .newFolder)
        ]
    }

    /// Needs approval's ⋯: its look, its switch and its runs; never Move or
    /// Delete.
    static func approvalsEntries(isEnabled: Bool) -> [InboxMenuEntry] {
        [
            InboxMenuEntry(title: "Edit the Look…", command: .editLook),
            isEnabled ? InboxMenuEntry(title: "Turn Off", command: .turnOff)
                      : InboxMenuEntry(title: "Turn On", command: .turnOn),
            InboxMenuEntry(title: "Run History", command: .runHistory)
        ]
    }

    /// The Idea finder legacy entry's ⋯ (moved from the Ideas filter's menu).
    static let ideaFinderEntries = [
        InboxMenuEntry(title: "Find Ideas in Past Messages…", command: .findIdeasInPastMessages)
    ]
}

/// The entries as a `Menu`'s content: a button per press, a submenu per
/// entry with children, a checkmark on the current choice.
struct InboxMenuItems: View {
    let entries: [InboxMenuEntry]
    let onCommand: (InboxMenuCommand) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            if entry.children.isEmpty {
                button(entry)
            } else {
                Menu(entry.title) {
                    Self(entries: entry.children, onCommand: onCommand)
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ entry: InboxMenuEntry) -> some View {
        let title = String(repeating: "   ", count: entry.indent) + entry.title
        Button(role: entry.destructive ? .destructive : nil) {
            if let command = entry.command { onCommand(command) }
        } label: {
            if entry.checked {
                Label(title, systemImage: "checkmark")
            } else if let image = entry.systemImage {
                Label(title, systemImage: image)
            } else {
                Text(title)
            }
        }
    }
}

/// A ⋯ button that opens `entries` (the artifact header, a folder row).
struct InboxMoreMenu: View {
    let entries: [InboxMenuEntry]
    var help = "More"
    let onCommand: (InboxMenuCommand) -> Void

    var body: some View {
        Menu {
            InboxMenuItems(entries: entries, onCommand: onCommand)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The reading pane's artifact header: the title, its source line, **Done**
/// and the artifact ⋯; a failed ⋯ entry's text under it, never silent
/// (spec: "Artifact ⋯ entry failed"). Values only; Task 14 wires it.
struct InboxArtifactHeader: View {
    let title: String
    let source: String
    let menu: InboxArtifactMenuContent
    /// The CLI's text of the last failed ⋯ press, or the busy line.
    var error: String?
    /// A ⋯ press under way: the menu waits.
    var isWorking = false
    var onDone: () -> Void = {}
    var onCommand: (InboxMenuCommand) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                if isWorking { ProgressView().controlSize(.small) }
                Button("Done", action: onDone)
                    .buttonStyle(.kitSecondary)
                InboxMoreMenu(entries: menu.entries, onCommand: onCommand)
                    .disabled(isWorking)
            }
            .controlSize(.small)
            Text(source)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
