import Foundation

/// The owner's per-start choice of where a new agent session runs.
package enum WorktreeChoice: String, Sendable, CaseIterable { case auto, folder, worktree }

/// Where a new workbench agent session starts (board #229, spec
/// 2026-10-14-session-worktrees-design.md §4). Pure; the view model feeds it
/// the folder's git status and whether a live agent already works in it.
package enum SessionStartPlacement: Equatable, Sendable {
    /// `note`: why a worktree was not used, when one was asked for or implied.
    case folder(note: String?)
    case worktree

    package static func decide(choice: WorktreeChoice, gitStatus: WorkbenchGitStatus?, occupied: Bool) -> Self {
        let wants = choice == .worktree || (choice == .auto && occupied)
        if !wants { return .folder(note: nil) }
        if let reason = unavailableReason(gitStatus) { return .folder(note: "Started in the folder: \(reason)") }
        return .worktree
    }

    /// nil when a worktree can be made; else the reason in words.
    package static func unavailableReason(_ s: WorkbenchGitStatus?) -> String? {
        guard let s else { return "the folder's git status could not be read." }
        if !s.gitAvailable { return "git is not available." }
        if !s.git { return "the folder is not in a git repository." }
        if !s.statusOK { return "the folder's git status could not be read." }
        if s.unborn { return "the repository has no commit yet." }
        return nil
    }

    /// A live agent row works in the main folder: its place is the main
    /// folder, or unknown and it was not placed in a worktree.
    package static func occupies(row: TerminalSession, place: SessionPlace, workbenchFolder: String) -> Bool {
        switch place {
        case .main: return true
        case .unknown:
            return row.worktreeBranch == nil
                && SessionPlace.isWorkbenchFolder(row.folderPath, workbenchFolder: workbenchFolder)
        case .worktree, .removed: return false
        }
    }

    /// `<target id>-<words>` or `session-<n>`: lowercase ASCII letters,
    /// digits and single dashes, at most 40 characters, no trailing dash.
    package static func slug(targetID: Int64?, targetText: String?, sessionNumber: Int) -> String {
        guard let targetID else { return "session-\(sessionNumber)" }
        let folded = (targetText ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let words = folded
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map(String.init)
        var out = "\(targetID)"
        for w in words where out.count + 1 + w.count <= 40 { out += "-" + w }
        return out
    }
}
