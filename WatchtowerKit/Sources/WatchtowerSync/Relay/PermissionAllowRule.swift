import Foundation

/// Why the phone may not allow a permission request, only deny it (#517,
/// owner decision in ask #268). The hub's `permission_answer` handler
/// refuses `allow` for one (`ActionReason.answerOnMac`, the row stays
/// pending) and the phone's card hides Allow once: one rule for both.
public enum PermissionAllowBlock: String, Equatable, Sendable {
    /// The summary was cut short: the owner never saw all of the request.
    case clipped
    /// An Edit, Write or NotebookEdit of a file that changes Claude Code's,
    /// an agent's, git's hooks or the shell's settings.
    case settingsPath

    /// The card's note and the hub's refusal message.
    public var note: String {
        switch self {
        case .clipped: "Shortened — answer on the Mac to allow"
        case .settingsPath: "Changes Watchtower or shell settings — answer on the Mac to allow"
        }
    }

    /// The tools whose summary is the file path they write.
    public static let pathTools: Set<String> = ["Edit", "Write", "NotebookEdit"]
    /// A path with one of these components is a settings path.
    static let settingsDirs: Set<String> = [".claude", ".codex", ".agents"]
    /// A file with one of these names is a settings path: shell rc and
    /// profile files, then the ones that run code or steer an agent (ask #312).
    static let settingsFiles: Set<String> = [
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile", ".bash_login", ".profile",
        ".mcp.json", ".envrc", ".gitconfig"
    ]
    /// A path with one of these folder/name pairs is a settings path.
    static let settingsPairs: Set<[String]> = [[".git", "hooks"], [".git", "config"], [".watchtower", "workflow.md"]]

    /// nil when the phone may allow the request once.
    public static func check(toolName: String, summary: String, clipped: Bool) -> Self? {
        if clipped { return .clipped }
        if pathTools.contains(toolName), isSettingsPath(summary) { return .settingsPath }
        return nil
    }

    /// The path has a `.claude`, `.codex` or `.agents` component, lies
    /// under `.git/hooks`, is `.git/config` or `.watchtower/workflow.md`, or
    /// names a file of `settingsFiles`. Compared case-insensitively: the
    /// Mac's default file system is.
    static func isSettingsPath(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        if parts.contains(where: settingsDirs.contains) { return true }
        if zip(parts, parts.dropFirst()).contains(where: { settingsPairs.contains([$0, $1]) }) { return true }
        return parts.last.map(settingsFiles.contains) ?? false
    }
}
