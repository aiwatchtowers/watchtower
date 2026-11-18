import Foundation

/// The words of the session start choice (board #229, spec
/// 2026-10-14-session-worktrees-design.md §10): the New session menus', the
/// disabled item's help and the setup command field's hint.
package enum SessionStartPlacementPresentation {
    package static func menuTitle(_ choice: WorktreeChoice) -> String {
        switch choice {
        case .auto: "Automatic"
        case .folder: "In This Folder"
        case .worktree: "In Its Own Worktree"
        }
    }

    /// `reason` is `SessionStartPlacement.unavailableReason`.
    package static func disabledHelp(_ reason: String) -> String { "A worktree cannot be made: \(reason)" }

    /// The start notice of a Work on It whose target's folder was removed
    /// from the bench (spec 2026-11-18 §6.3): the session starts in home.
    package static func folderLeftTheBench(home: String, folder: String) -> String {
        "Started in \(home): the target's folder \(folder) left the bench."
    }

    package static let setupHint =
        "Runs in a new session worktree before the agent starts, after the .worktreeinclude paths are copied. Leave empty for none."
}
