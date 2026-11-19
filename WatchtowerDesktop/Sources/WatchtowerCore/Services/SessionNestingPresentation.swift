import Foundation

/// The sessions panel's sub-sessions and folders (spec 2026-11-18 §6.4–§6.6,
/// board #2003): children nested under their parent, the folder label of a
/// row on a bench of several folders, a child's strip trail and its way back
/// to the parent, the agent message left in a prompt, and the New Session
/// menu's per-folder items. Pure, so every string has a test.
package enum SessionNestingPresentation {
    // MARK: - Nesting

    /// `rows` in panel order with each child moved under its parent, one
    /// level deeper per parent (§6.5). A child whose parent is not among
    /// `rows` (deleted, in another list) stays where it is at depth 0; the
    /// order of siblings is `rows`' own. A parent loop (never written by
    /// Go) is broken at the first row met again.
    package static func nest(_ rows: [TerminalSession]) -> [(row: TerminalSession, depth: Int)] {
        let listed = Set(rows.map(\.id))
        var children: [Int64: [TerminalSession]] = [:]
        var tops: [TerminalSession] = []
        for row in rows {
            if let parent = row.parentSessionID, parent != row.id, listed.contains(parent) {
                children[parent, default: []].append(row)
            } else {
                tops.append(row)
            }
        }
        var out: [(row: TerminalSession, depth: Int)] = []
        var placed: Set<Int64> = []
        func place(_ row: TerminalSession, depth: Int) {
            guard placed.insert(row.id).inserted else { return }
            out.append((row, depth))
            for child in children[row.id] ?? [] { place(child, depth: depth + 1) }
        }
        tops.forEach { place($0, depth: 0) }
        // Rows only reachable through a loop: listed at the top, once each.
        rows.filter { !placed.contains($0.id) }.forEach { place($0, depth: 0) }
        return out
    }

    /// The parent row's state line suffix (§6.5): `· 1 sub-session`, `· 3
    /// sub-sessions`; nil without a live sub-session.
    package static func subSessionsSuffix(_ count: Int) -> String? {
        switch count {
        case ...0: nil
        case 1: "· 1 sub-session"
        default: "· \(count) sub-sessions"
        }
    }

    // MARK: - Folders

    /// The folder name a session row shows before its place (§6.2): only on
    /// a bench of more than one live folder — a one-folder bench looks as
    /// today (§2 anti-goal). A row with no folder stored is in the home
    /// folder; nil for a folder this bench does not hold.
    package static func folderLabel(folderID: Int64?, folders: BenchFolders?) -> String? {
        guard let folders, folders.live.count > 1 else { return nil }
        return folders.folder(folderID)?.name
    }

    /// A child's session strip (§6.5): `📁 hub › ⑂ export-api › ⎇
    /// wt/export-api ●`; `worktree` nil for a session in its folder, `●`
    /// only while the branch has uncommitted changes.
    package static func stripTrail(folder: String, worktree: String?, branch: String?, dirty: Bool) -> String {
        var parts = ["📁 \(folder)"]
        if let worktree { parts.append("⑂ \(worktree)") }
        if let branch { parts.append("⎇ \(branch)" + (dirty ? " ●" : "")) }
        return parts.joined(separator: " › ")
    }

    /// The trailing link on a child's strip that opens its parent (§6.5).
    package static func fromParent(title: String) -> String { "↖ from “\(title)”" }

    // MARK: - An agent message in the prompt (§6.6)

    /// The row's state line suffix while an agent's message may still sit
    /// typed in the session's prompt; drawn in the warning tone.
    package static let promptWaiting = "· Agent message waiting in the prompt"

    /// The pane's notice for the same.
    package static let promptNotice = "An agent's message is in the prompt. Press Return in the terminal to send it."

    package static let showInTerminal = "Show in Terminal"

    /// Only for a session host without the `prompt_state` request (spec §5,
    /// D41): nothing else can tell the prompt was cleared.
    package static let dismiss = "Dismiss"

    /// Whether the notice offers Dismiss.
    package static func offersDismiss(hostHasPromptState: Bool) -> Bool { !hostHasPromptState }

    // MARK: - New Session (+) per folder (§6.4)

    /// The submenu that starts a session in another folder of the bench.
    package static func folderSubmenuTitle(_ folder: String) -> String { "in \(folder)" }

    /// The New Session (+) menu of a bench: the top agent items start in the
    /// context folder; with more than one live folder each other folder
    /// gets an `in <folder>` submenu, and the placement submenus list every
    /// folder.
    package struct NewSessionMenu: Equatable, Sendable {
        package struct FolderItem: Equatable, Sendable {
            package let folderID: Int64
            package let title: String
        }

        /// The folder the top items start in.
        package let contextFolderID: Int64
        /// `in <folder>`, one per live folder but the context one, in position order.
        package let otherFolders: [FolderItem]
        /// The `In This Folder ▸` / `In Its Own Worktree ▸` submenus' folder
        /// level; empty on a one-folder bench (the agents sit right there).
        package let placementFolders: [FolderItem]
    }

    package static func newSessionMenu(folders: BenchFolders, contextFolderID: Int64) -> NewSessionMenu {
        let live = folders.live
        guard live.count > 1 else {
            return NewSessionMenu(contextFolderID: contextFolderID, otherFolders: [], placementFolders: [])
        }
        return NewSessionMenu(
            contextFolderID: contextFolderID,
            otherFolders: live.filter { $0.id != contextFolderID }
                .map { .init(folderID: $0.id, title: folderSubmenuTitle($0.name)) },
            placementFolders: live.map { .init(folderID: $0.id, title: $0.name) }
        )
    }
}
