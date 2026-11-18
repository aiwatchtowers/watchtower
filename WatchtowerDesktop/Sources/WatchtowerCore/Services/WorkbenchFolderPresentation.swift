import Foundation

/// The words and states of a workbench's folders in FILES, the switcher and
/// Put on the Bench… (#2003, spec 2026-11-18-multi-folder-workbench §6.1,
/// §6.2, §6.14). Pure: the view model hands in what it read, the views draw
/// what comes back (colours through `Tone`, by `Emphasis`).
package enum WorkbenchFolderPresentation {
    /// How a root's trailing text is drawn.
    package enum Emphasis: Equatable, Sendable {
        case secondary
        case warning
        case error
    }

    /// A FILES root's state (§6.2), first match wins: a folder that is gone,
    /// then an install that is missing, then git.
    package enum RootState: Equatable, Sendable {
        case normal
        /// The folder was moved or deleted: `Locate…` · `Remove`.
        case notFound
        /// No git on the Mac.
        case gitUnavailable
        /// The folder is no git work tree: no branch on the right.
        case notRepository
        /// Watchtower's install is not in the folder: the install icon and Retry.
        case installMissing

        /// The text on the right instead of the branch line; nil = the branch line.
        package var trailing: String? {
            switch self {
            case .normal, .installMissing: nil
            case .notFound: "Folder not found"
            case .gitUnavailable: "Git unavailable"
            case .notRepository: "Not a repository"
            }
        }

        package var emphasis: Emphasis {
            switch self {
            case .notFound: .error
            case .gitUnavailable, .installMissing: .warning
            case .normal, .notRepository: .secondary
            }
        }

        /// The folder's name is drawn in the error tone.
        package var namesAnError: Bool { self == .notFound }
    }

    // MARK: Put on the Bench (§6.1)

    /// The FILES header's and the switcher's icon (Open Folder… keeps `folder.badge.plus`).
    package static let putOnBenchIcon = "plus.rectangle.on.folder"
    package static let putOnBenchTitle = "Put on the Bench…"
    package static let tooltip = "Put on the Bench…"
    /// The folder panel's title and button.
    package static let panelTitle = "Put on the Bench"
    package static let panelPrompt = "Put on Bench"

    package static func putOnBenchSubtitle(bench: String) -> String {
        "Add a folder to “\(bench)”"
    }

    /// The quiet hint under a one-folder tree: its lead, then the link.
    package static let hintLead = "Task touches another repo?"
    package static let hint = "\(hintLead) \(putOnBenchTitle)"

    /// An add that failed or was refused, under the FILES header.
    package static func putOnBenchFailed(name: String, reason: String) -> String {
        "Couldn’t put \(name) on the bench: \(reason)"
    }

    // MARK: Root rows (§6.2)

    package static let showInFinder = "Show in Finder"
    package static let newSessionHere = "New Session Here"
    package static let removeFromBench = "Remove from Bench…"
    package static let locate = "Locate…"
    package static let remove = "Remove"
    package static let retry = "Retry"

    /// The line under a root whose folder is gone.
    package static func notFoundDetail(path: String, home: String = NSHomeDirectory()) -> String {
        "\(abbreviated(path, home: home)) was moved or deleted."
    }

    /// The install icon's tooltip on a root whose install is missing.
    package static func installMissingHelp(name: String) -> String {
        "Watchtower is not installed in \(name). Sessions can’t start there until it is — Retry sets it up again."
    }

    /// A session start refused for a folder without the install (§6.1).
    package static func startRefusedNotInstalled(name: String) -> String {
        "Install Watchtower in \(name) first"
    }

    /// A root's label: the folder's stored name, and its parent directory as
    /// a caption when another folder of the bench has the same last path
    /// component (two `app` checkouts side by side).
    package static func rootName(
        _ folder: WorkbenchFolder, siblings: [WorkbenchFolder], home: String = NSHomeDirectory()
    ) -> (name: String, caption: String?) {
        let last = folder.url.lastPathComponent
        let twin = siblings.contains {
            $0.id != folder.id && $0.url.lastPathComponent.caseInsensitiveCompare(last) == .orderedSame
        }
        guard twin else { return (folder.name, nil) }
        return (folder.name, abbreviated(folder.url.deletingLastPathComponent().path, home: home))
    }

    package static func rootState(exists: Bool, gitAvailable: Bool, isRepository: Bool, installed: Bool) -> RootState {
        if !exists { return .notFound }
        if !installed { return .installMissing }
        if !gitAvailable { return .gitUnavailable }
        if !isRepository { return .notRepository }
        return .normal
    }

    /// `⎇ main`, `⎇ feature/x ● ↑2`, `⎇ main ↓1`: the branch (the hash on a
    /// detached HEAD), a dot for uncommitted changes, the upstream counters.
    package static func branchLine(_ status: WorkbenchGitStatus) -> String {
        var parts = ["⎇ " + WorkbenchBranchPresentation.label(status).text]
        if status.dirty { parts.append("●") }
        if let counters = WorkbenchBranchPresentation.counters(status) { parts.append(counters) }
        return parts.joined(separator: " ")
    }

    // MARK: Remove from Bench / Locate (§6.3)

    /// The confirmation, or a refusal (`OK` only), before or instead of a
    /// remove.
    package struct RemoveDialog: Equatable, Sendable {
        package let title: String
        package let message: String
        /// `Cancel` · `Remove` (destructive); otherwise `OK`.
        package let confirms: Bool
    }

    package static let cancel = "Cancel"
    package static let ok = "OK"

    package static func removeConfirm(name: String) -> RemoveDialog {
        RemoveDialog(
            title: "Remove \(name) from the bench?",
            message: "Watchtower's install in this folder is removed. Your files and git are not touched.",
            confirms: true
        )
    }

    package static func removeRefusedTitle(name: String) -> String {
        "Can’t remove \(name) from the bench"
    }

    package static func removeRefusedSessions(name: String, count: Int) -> RemoveDialog {
        let message = count == 1
            ? "1 session is running in \(name). Finish it first."
            : "\(count) sessions are running in \(name). Finish them first."
        return RemoveDialog(title: removeRefusedTitle(name: name), message: message, confirms: false)
    }

    package static func removeRefusedLast(name: String) -> RemoveDialog {
        RemoveDialog(title: removeRefusedTitle(name: name), message: "A workbench needs at least one folder.", confirms: false)
    }

    /// A refusal Go sent after the confirmation (a session started
    /// meanwhile): its own sentence.
    package static func removeRefused(name: String, reason: String) -> RemoveDialog {
        RemoveDialog(title: removeRefusedTitle(name: name), message: reason, confirms: false)
    }

    /// A remove that failed, under the FILES header.
    package static func removeFailed(name: String, reason: String) -> String {
        "Couldn’t remove \(name) from the bench: \(reason)"
    }

    /// Locate…'s folder panel: its title and button.
    package static func locatePanelTitle(name: String) -> String {
        "Locate \(name)"
    }

    package static let locatePanelPrompt = "Choose"

    /// A Locate… that failed or was refused, under the FILES header.
    package static func locateFailed(name: String, reason: String) -> String {
        "Couldn’t locate \(name): \(reason)"
    }

    // MARK: Switcher (§6.14)

    /// A multi-folder bench's folders after its name in the switcher
    /// (`app, hub, site`); nil for a one-folder bench. The view truncates
    /// it at the tail.
    package static func switcherFolders(_ names: [String]) -> String? {
        names.count > 1 ? names.joined(separator: ", ") : nil
    }

    /// `~/code/hub` for a path under the home folder.
    package static func abbreviated(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
