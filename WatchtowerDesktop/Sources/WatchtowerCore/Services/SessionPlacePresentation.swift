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
    /// `stale` (the place's last read failed) adds a note to the help.
    package static func placeLabel(_ place: SessionPlace, mainStatus: WorkbenchGitStatus?, stale: Bool = false) -> PlaceLabel {
        let label = freshLabel(place, mainStatus: mainStatus)
        guard stale else { return label }
        return PlaceLabel(text: label.text, systemImage: label.systemImage, help: label.help + "\n" + staleNote)
    }

    package static let staleNote = "Could not read it again — it may be out of date."

    private static func freshLabel(_ place: SessionPlace, mainStatus: WorkbenchGitStatus?) -> PlaceLabel {
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

    /// The session row's place line (board #987): the place, led by the
    /// branch the session's work merges into when that is not the branch
    /// the agent's terminal sits on, plus its lane worktrees.
    /// `⎇ feature/x · 3 lanes` (the terminal's place moves to the help),
    /// `⎇ 2 target branches`, `main folder · main · 1 lane`. No target
    /// branch and no lanes = `placeLabel`. The header's crumb keeps
    /// `placeLabel`: it sits beside the branch button of the page's root.
    package static func rowLabel(
        _ place: SessionPlace,
        mainStatus: WorkbenchGitStatus?,
        stale: Bool = false,
        targetBranch: SessionTargetBranch?,
        lanes: [String] = []
    ) -> PlaceLabel {
        let base = placeLabel(place, mainStatus: mainStatus, stale: stale)
        let lanesText = lanes.isEmpty ? "" : " · " + (lanes.count == 1 ? "1 lane" : "\(lanes.count) lanes")
        let lanesHelp = lanes.isEmpty ? [] : ["Lane worktrees: " + lanes.joined(separator: ", ")]
        switch targetBranch {
        case nil:
            return PlaceLabel(text: base.text + lanesText, systemImage: base.systemImage,
                              help: ([base.help] + lanesHelp).joined(separator: "\n"))
        case let .one(branch) where branch == placeBranch(place, mainStatus: mainStatus):
            return PlaceLabel(text: base.text + lanesText, systemImage: base.systemImage,
                              help: (["Target branch: \(branch)", base.help] + lanesHelp).joined(separator: "\n"))
        case let .one(branch):
            return PlaceLabel(text: "⎇ \(branch)" + lanesText, systemImage: worktreeSymbol,
                              help: (["Target branch: \(branch)", "Terminal: \(base.text)", base.help] + lanesHelp)
                                  .joined(separator: "\n"))
        case let .several(branches):
            return PlaceLabel(text: "⎇ \(branches.count) target branches" + lanesText, systemImage: worktreeSymbol,
                              help: (["Target branches: " + branches.joined(separator: ", "),
                                      "Terminal: \(base.text)", base.help] + lanesHelp).joined(separator: "\n"))
        }
    }

    /// The branch the place's checkout is on; nil when it is detached, not
    /// read, or the worktree is gone.
    private static func placeBranch(_ place: SessionPlace, mainStatus: WorkbenchGitStatus?) -> String? {
        let status: WorkbenchGitStatus?
        switch place {
        case .unknown, .main: status = mainStatus
        case let .worktree(_, _, worktreeStatus): status = worktreeStatus
        case .removed: status = nil
        }
        guard let status, WorkbenchBranchPresentation.showsButton(status), !status.detached,
              !status.branch.isEmpty else { return nil }
        return status.branch
    }

    private static func withBranch(_ prefix: String, _ status: WorkbenchGitStatus?) -> String {
        guard let status, WorkbenchBranchPresentation.showsButton(status) else { return prefix }
        let branch = WorkbenchBranchPresentation.label(status).text
        return branch.isEmpty ? prefix : "\(prefix) · \(branch)"
    }
}
