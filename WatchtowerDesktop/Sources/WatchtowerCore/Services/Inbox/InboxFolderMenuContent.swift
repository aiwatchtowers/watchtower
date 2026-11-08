import Foundation

/// A folder of the Inbox menu (spec "The model" → Folders): the root, Needs
/// approval, or one of the owner's. One type with the folder read's
/// (`InboxFolder.Kind`), so a row is built from a folder without mapping.
package typealias InboxFolderKind = InboxFolder.Kind

/// One row of the folder menu, in tree order. `depth` is 0 for the root;
/// a row's children are the rows right after it with a greater depth.
package struct InboxFolderRow: Identifiable, Equatable, Sendable {
    package let id: Int64
    package let kind: InboxFolderKind
    package let title: String
    /// An SF Symbol of the allowlist; empty draws `folder`.
    package let icon: String
    package let depth: Int
    /// The folder's own count (not its children's); 0 draws none.
    package let count: Int
    package var hidden: Bool
    package var isExpanded: Bool

    package init(
        id: Int64,
        kind: InboxFolderKind,
        title: String,
        icon: String,
        depth: Int,
        count: Int,
        hidden: Bool = false,
        isExpanded: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.icon = icon
        self.depth = depth
        self.count = count
        self.hidden = hidden
        self.isExpanded = isExpanded
    }

    package var systemImage: String {
        switch kind {
        case .root: "tray"
        case .approvals: "checkmark.circle"
        case .owner: icon.isEmpty ? "folder" : icon
        }
    }
}

/// One icon of the folder allowlist: its SF Symbol and the name Icon ▸
/// shows ("Flag", "People", "Box").
package struct InboxFolderIcon: Equatable, Sendable {
    package let symbol: String
    package let label: String

    package init(symbol: String, label: String) {
        self.symbol = symbol
        self.label = label
    }
}

/// The one line under the menu: a lost revision race reloaded the tree, or
/// the CLI is missing and every edit is off.
package enum InboxFolderMenuNote: Equatable, Sendable {
    case menuChanged, cliUnavailable

    package var text: String {
        switch self {
        case .menuChanged: "The menu changed — reloaded. Drag again if needed."
        case .cliUnavailable: "The watchtower CLI isn't available"
        }
    }
}

/// Where a drag would drop: above `targetID` among its siblings, or into it
/// as its last child. A refused drop has none.
package struct InboxFolderDrop: Equatable, Sendable {
    package enum Placement: Equatable, Sendable { case before, into }
    package let targetID: Int64
    package let placement: Placement

    package init(targetID: Int64, placement: Placement) {
        self.targetID = targetID
        self.placement = placement
    }
}

/// The inline Delete… confirmation under a folder row: what moves up to
/// the folder's parent (the root, "Inbox", for a top-level folder).
package struct InboxFolderDeleteSummary: Equatable, Sendable {
    package let folderID: Int64
    package let title: String
    package let folders: Int
    package let automations: Int
    package let artifacts: Int
    package let parentTitle: String

    package init(
        folderID: Int64,
        title: String,
        folders: Int,
        automations: Int,
        artifacts: Int,
        parentTitle: String = "Inbox"
    ) {
        self.folderID = folderID
        self.title = title
        self.folders = folders
        self.automations = automations
        self.artifacts = artifacts
        self.parentTitle = parentTitle
    }

    package var text: String {
        let parts = [Self.count(folders, "folder"), Self.count(automations, "automation"),
                     Self.count(artifacts, "artifact")].compactMap { $0 }
        guard !parts.isEmpty else { return "Delete “\(title)”? It is empty." }
        let list = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "Delete “\(title)”? Its \(list) move to \(parentTitle)."
    }

    private static func count(_ value: Int, _ noun: String) -> String? {
        value == 0 ? nil : "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// The inline title field of New Folder (under a parent; nil = the root)
/// or Rename (of a folder), with a refused write's message under it.
package struct InboxFolderDraft: Equatable, Sendable {
    package enum Target: Equatable, Sendable {
        case create(parent: Int64?)
        case rename(Int64)
    }

    package var target: Target
    package var title: String
    /// The CLI's message without "Error: "; the field stays open.
    package var error: String?

    package init(_ target: Target, title: String, error: String? = nil) {
        self.target = target
        self.title = title
        self.error = error
    }
}

/// A refused (or unconfirmed) folder write outside the title field: the
/// CLI's message under the row it was about, or under the menu when that
/// row is not on screen. The next edit clears it.
package struct InboxFolderMenuRefusal: Equatable, Sendable {
    package let folderID: Int64?
    package let message: String

    package init(folderID: Int64?, message: String) {
        self.folderID = folderID
        self.message = message
    }
}

/// Everything the menu draws, as plain values (plan Task 1): Task 11's
/// `InboxFolderMenuModel` builds it from the folder read and its writes.
package struct InboxFolderMenuContent: Equatable, Sendable {
    package var rows: [InboxFolderRow]
    package var selection: Int64?
    package var note: InboxFolderMenuNote?
    package var dropIndicator: InboxFolderDrop?
    /// The folder a live drag carries; nil = no drop is taken.
    package var draggedID: Int64?
    package var deleteConfirmation: InboxFolderDeleteSummary?
    package var folderDraft: InboxFolderDraft?
    /// A refused write's message; a draft's own refusal is `folderDraft.error`.
    package var refusal: InboxFolderMenuRefusal?
    /// A dropped folder sits dimmed in its new place while the move runs;
    /// the menu is read-only meanwhile.
    package var pendingMoveID: Int64?
    /// The root's ⋯ Show Hidden Folders is on.
    package var showsHidden: Bool
    /// Icon ▸'s allowlist (`InboxFolderIcons`).
    package var icons: [InboxFolderIcon]
    /// Needs approval's built-in is on: its ⋯ offers Turn Off, else Turn On.
    package var approvalsEnabled: Bool

    package init(
        rows: [InboxFolderRow],
        selection: Int64? = nil,
        note: InboxFolderMenuNote? = nil,
        dropIndicator: InboxFolderDrop? = nil,
        draggedID: Int64? = nil,
        deleteConfirmation: InboxFolderDeleteSummary? = nil,
        folderDraft: InboxFolderDraft? = nil,
        refusal: InboxFolderMenuRefusal? = nil,
        pendingMoveID: Int64? = nil,
        showsHidden: Bool = false,
        icons: [InboxFolderIcon] = [],
        approvalsEnabled: Bool = true
    ) {
        self.rows = rows
        self.selection = selection
        self.note = note
        self.dropIndicator = dropIndicator
        self.draggedID = draggedID
        self.deleteConfirmation = deleteConfirmation
        self.folderDraft = folderDraft
        self.refusal = refusal
        self.pendingMoveID = pendingMoveID
        self.showsHidden = showsHidden
        self.icons = icons
        self.approvalsEnabled = approvalsEnabled
    }

    /// No edit, drag or menu write: the CLI is missing or a move runs.
    package var isReadOnly: Bool { note == .cliUnavailable || pendingMoveID != nil }

    /// The rows drawn. `rows` is the whole tree; this is the one place that
    /// leaves out a collapsed folder's descendants and — unless Show Hidden
    /// Folders is on — a hidden folder with everything below it.
    package var visibleRows: [InboxFolderRow] {
        collapsing(shownRows)
    }

    /// Whether `row` has a child on screen once expanded: a folder whose
    /// children are all hidden (Show Hidden Folders off) has none, so it
    /// draws no chevron. Collapsing does not count — a collapsed folder
    /// keeps its chevron.
    package func hasChildren(_ row: InboxFolderRow) -> Bool {
        let shown = shownRows
        guard let index = shown.firstIndex(of: row), shown.indices.contains(index + 1) else { return false }
        return shown[index + 1].depth > row.depth
    }

    /// The tree without the hidden folders and their subtrees, unless
    /// Show Hidden Folders is on.
    private var shownRows: [InboxFolderRow] {
        guard !showsHidden else { return rows }
        var skipBelow: Int?
        return rows.filter { row in
            if let depth = skipBelow {
                if row.depth > depth { return false }
                skipBelow = nil
            }
            if row.hidden {
                skipBelow = row.depth
                return false
            }
            return true
        }
    }

    /// `rows` without the descendants of a collapsed folder.
    private func collapsing(_ rows: [InboxFolderRow]) -> [InboxFolderRow] {
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
}

/// What a press in one of the Inbox's ⋯ menus asks for (spec "The Inbox
/// screen" → Menus). The views only emit it; Task 14 carries it out through
/// the Automations tab's own verbs and `watchtower inbox folders …`.
package enum InboxMenuCommand: Hashable, Sendable {
    // The artifact ⋯ (and Needs approval's).
    case runNow, editCollects, editLook, schedule, moveTo(folderID: Int64), turnOff, turnOn, runHistory, delete
    // An owner folder's ⋯.
    case rename, icon(String), newFolderInside, hide, show, deleteFolder
    // The root's ⋯.
    case learnedRules, assistantProfile, showHiddenFolders, hideHiddenFolders, newFolder
    // The Idea finder legacy entry's ⋯.
    case findIdeasInPastMessages

    /// A press that only opens or shows something: it stays available while
    /// the menu is read-only (the CLI is missing, a move runs).
    package var isRead: Bool {
        switch self {
        case .learnedRules, .assistantProfile, .runHistory, .showHiddenFolders, .hideHiddenFolders: true
        default: false
        }
    }
}

/// One entry of an Inbox ⋯ menu: a press, or a submenu (`children`) such as
/// **Move to Folder ▸** and **Icon ▸**. `checked` marks the current choice,
/// `indent` a folder's depth inside Move to Folder.
package struct InboxMenuEntry: Equatable, Sendable {
    package let title: String
    package var command: InboxMenuCommand?
    package var destructive: Bool
    package var checked: Bool
    package var indent: Int
    package var systemImage: String?
    package var children: [Self]

    package init(
        title: String,
        command: InboxMenuCommand? = nil,
        destructive: Bool = false,
        checked: Bool = false,
        indent: Int = 0,
        systemImage: String? = nil,
        children: [Self] = []
    ) {
        self.title = title
        self.command = command
        self.destructive = destructive
        self.checked = checked
        self.indent = indent
        self.systemImage = systemImage
        self.children = children
    }
}

/// Which entries an artifact's ⋯ offers (spec: a built-in has no Delete…,
/// Needs approval's automation has no Move to Folder, a built-in without
/// Run Now has none). Plain values; Task 14 fills them from the automation.
package struct InboxArtifactMenuContent: Equatable, Sendable {
    package var isBuiltin: Bool
    package var offersRunNow: Bool
    package var movable: Bool
    package var isEnabled: Bool
    /// The folders Move to Folder ▸ offers: every folder but Needs approval.
    package var folders: [InboxFolderRow]
    /// The folder the automation's route points at; the root when nil.
    package var currentFolderID: Int64?

    package init(
        isBuiltin: Bool = false,
        offersRunNow: Bool = true,
        movable: Bool = true,
        isEnabled: Bool = true,
        folders: [InboxFolderRow] = [],
        currentFolderID: Int64? = nil
    ) {
        self.isBuiltin = isBuiltin
        self.offersRunNow = offersRunNow
        self.movable = movable
        self.isEnabled = isEnabled
        self.folders = folders
        self.currentFolderID = currentFolderID
    }

    package var entries: [InboxMenuEntry] {
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
    package static func moveTargets(_ folders: [InboxFolderRow], current: Int64?) -> [InboxMenuEntry] {
        let rootID = folders.first { $0.kind == .root }?.id
        return folders.filter { $0.kind != .approvals }.map { folder in
            InboxMenuEntry(title: folder.title, command: .moveTo(folderID: folder.id),
                           checked: folder.id == (current ?? rootID), indent: folder.depth)
        }
    }

    /// An owner folder's ⋯: Rename…, Icon ▸ (the allowlist), New Folder
    /// Inside, Hide or Show, Delete….
    package static func folderEntries(_ folder: InboxFolderRow, icons: [InboxFolderIcon]) -> [InboxMenuEntry] {
        [
            InboxMenuEntry(title: "Rename…", command: .rename),
            InboxMenuEntry(title: "Icon", children: icons.map { icon in
                InboxMenuEntry(title: icon.label, command: .icon(icon.symbol), checked: icon.symbol == folder.icon,
                               systemImage: icon.symbol)
            }),
            InboxMenuEntry(title: "New Folder Inside", command: .newFolderInside),
            folder.hidden ? InboxMenuEntry(title: "Show", command: .show) : InboxMenuEntry(title: "Hide", command: .hide),
            InboxMenuEntry(title: "Delete…", command: .deleteFolder, destructive: true)
        ]
    }

    /// The root's ⋯: the two panes the old header ⋯ held, Show (or Hide)
    /// Hidden Folders, New Folder.
    package static func rootEntries(showingHidden: Bool) -> [InboxMenuEntry] {
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
    package static func approvalsEntries(isEnabled: Bool) -> [InboxMenuEntry] {
        [
            InboxMenuEntry(title: "Edit the Look…", command: .editLook),
            isEnabled ? InboxMenuEntry(title: "Turn Off", command: .turnOff)
                      : InboxMenuEntry(title: "Turn On", command: .turnOn),
            InboxMenuEntry(title: "Run History", command: .runHistory)
        ]
    }

    /// The Idea finder legacy entry's ⋯ (moved from the Ideas filter's menu).
    package static let ideaFinderEntries = [
        InboxMenuEntry(title: "Find Ideas in Past Messages…", command: .findIdeasInPastMessages)
    ]
}
