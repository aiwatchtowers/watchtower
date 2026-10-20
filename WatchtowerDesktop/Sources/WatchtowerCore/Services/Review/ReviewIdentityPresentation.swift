import Foundation

/// The Branch review identity bar's lines and the header Review button rule
/// (board #712, spec 2026-10-20-branch-review-design §4.2, §5). Pure: the
/// view passes the session's place, git status, round and diff files.
package enum ReviewIdentityPresentation {
    /// Branches that are the base of work, not work: reviewing them shows only uncommitted edits.
    package static let defaultBranchNames: Set<String> = ["main", "master"]

    /// The branch line: `feature/x ← main · 8 files · +212 −40 · 2 uncommitted · worktree x`.
    package struct BranchLine: Equatable, Sendable {
        package var branch: String
        /// The base without `origin/`; nil on the default branch, an empty tree or no round.
        package var base: String?
        /// The base commit, or `empty tree`.
        package var baseHelp: String
        /// `8 files · +212 −40`, the on-default-branch notice, or nil without files.
        package var size: String?
        package var uncommitted: String?
        package var place: String
        package var onDefaultBranch: Bool
    }

    /// The first linked target and how many more follow it.
    package struct ForLine: Equatable, Sendable {
        package var first: ReviewContextItem
        package var more: Int
    }

    /// The worktree's own status for `.worktree`, the main folder's otherwise.
    package static func status(place: SessionPlace, mainStatus: WorkbenchGitStatus?) -> WorkbenchGitStatus? {
        if case let .worktree(_, _, status) = place { return status }
        return mainStatus
    }

    /// `stale` (the last status read failed) adds the place-label note to `baseHelp`.
    package static func branchLine(
        place: SessionPlace,
        status: WorkbenchGitStatus?,
        round: ReviewRoundInfo?,
        files: [ReviewDiffFile],
        stale: Bool
    ) -> BranchLine {
        let branch = branchName(status)
        let rawBase = round.map { $0.baseLabel.hasPrefix("origin/") ? String($0.baseLabel.dropFirst("origin/".count)) : $0.baseLabel }
        let base = (rawBase?.isEmpty ?? true) ? nil : rawBase
        let onDefault: Bool
        if round != nil {
            onDefault = base != nil && base == branch
        } else {
            onDefault = defaultBranchNames.contains(branch)
        }
        var help = (round?.baseSha.isEmpty ?? true) ? "empty tree" : (round?.baseSha ?? "empty tree")
        if stale { help += "\n" + SessionPlacePresentation.staleNote }
        var uncommitted: String?
        if let status, status.dirty, status.changes > 0 { uncommitted = "\(status.changes) uncommitted" }
        return BranchLine(
            branch: branch,
            base: onDefault ? nil : base,
            baseHelp: help,
            size: onDefault ? "On \(branch) — only uncommitted edits are reviewed" : sizeText(files),
            uncommitted: uncommitted,
            place: placeText(place),
            onDefaultBranch: onDefault
        )
    }

    package static func forLine(_ items: [ReviewContextItem]) -> ForLine? {
        guard let first = items.first else { return nil }
        return ForLine(first: first, more: items.count - 1)
    }

    /// An agent session shows the header Review button when its work is not
    /// plainly the default branch with nothing to review; the open pane always does.
    package static func showsReviewButton(isAgent: Bool, status: WorkbenchGitStatus?, paneOnScreen: Bool) -> Bool {
        if paneOnScreen { return true }
        guard isAgent, let status else { return false }
        return status.dirty || status.detached || !defaultBranchNames.contains(status.branch)
    }

    private static func branchName(_ status: WorkbenchGitStatus?) -> String {
        guard let status else { return "" }
        if status.detached { return status.head.isEmpty ? "detached" : "detached at \(status.head)" }
        return WorkbenchBranchPresentation.label(status).text
    }

    private static func sizeText(_ files: [ReviewDiffFile]) -> String? {
        guard !files.isEmpty else { return nil }
        let added = files.reduce(0) { $0 + $1.additions }
        let removed = files.reduce(0) { $0 + $1.deletions }
        return "\(files.count) \(files.count == 1 ? "file" : "files") · +\(added) −\(removed)"
    }

    private static func placeText(_ place: SessionPlace) -> String {
        switch place {
        case let .worktree(name, _, _): return "worktree \(name)"
        case .removed: return "worktree removed"
        case .main, .unknown: return "main folder"
        }
    }
}
