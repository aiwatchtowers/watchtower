import Foundation

/// A session's place as one short line (board #565): the session row's
/// secondary line and the switcher popover. Pure; the branch of the main
/// folder comes from the header's own status.
package enum SessionPlacePresentation {
    package struct PlaceLabel: Equatable, Sendable {
        /// Self-contained (carries the `⑂` glyph for a worktree), for plain text.
        package let text: String
        /// SF Symbol for views that draw an icon beside the text.
        package let systemImage: String
        package let help: String
    }

    package static let worktreeSymbol = "arrow.triangle.branch"
    package static let mainSymbol = "folder"
    package static let removedSymbol = "folder.badge.minus"

    /// `⑂ mobile-a · feature/x`, `main folder · main`, `worktree removed`.
    /// Unknown shows as the main folder (D10). A branch that cannot be read
    /// is left out; detached HEAD and unborn branches read as the header's
    /// button does (`WorkbenchBranchPresentation.label`).
    package static func placeLabel(_ place: SessionPlace, mainStatus: WorkbenchGitStatus?) -> PlaceLabel {
        switch place {
        case .unknown:
            return PlaceLabel(text: withBranch("main folder", mainStatus), systemImage: mainSymbol,
                              help: "Where the agent works is not known yet — shown as the main folder")
        case .main:
            return PlaceLabel(text: withBranch("main folder", mainStatus), systemImage: mainSymbol,
                              help: "The agent works in the workbench folder")
        case let .worktree(name, root, status):
            return PlaceLabel(text: withBranch("⑂ \(name)", status), systemImage: worktreeSymbol,
                              help: "The agent works in the worktree \(root.path)")
        case let .removed(_, path):
            return PlaceLabel(text: "worktree removed", systemImage: removedSymbol,
                              help: "The agent's last folder no longer exists: \(path)")
        }
    }

    private static func withBranch(_ prefix: String, _ status: WorkbenchGitStatus?) -> String {
        guard let status, WorkbenchBranchPresentation.showsButton(status) else { return prefix }
        let branch = WorkbenchBranchPresentation.label(status).text
        return branch.isEmpty ? prefix : "\(prefix) · \(branch)"
    }
}
