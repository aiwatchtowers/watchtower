import Foundation

/// How an embedded terminal starts (spec §6.2): the owner's own login shell,
/// so `PATH` and `claude`'s auth are exactly theirs. A Claude session `exec`s
/// `claude` in the folder with a session id the app chose, so it can be
/// resumed later. The prompt, when present, is only ever one of the fixed
/// constants below — never owner data on the command line.
package struct TerminalLaunch: Equatable, Sendable {
    package enum Mode: Equatable, Sendable {
        case newClaude(uuid: String, prompt: String?)
        case resumeClaude(uuid: String)
        case shell
    }

    package static let firstRunPrompt = "Set up this Watchtower project using the watchtower-project skill."
    package static let fallbackShell = "/bin/zsh"

    package let executable: String
    package let args: [String]
    package let currentDirectory: String

    /// Does not validate `uuid`: callers check `isValidSessionID` first.
    package static func make(shell: String?, folder: String, mode: Mode) -> Self {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let args: [String]
        switch mode {
        case let .newClaude(uuid, prompt):
            args = ["-l", "-c", "exec claude --session-id \(uuid)" + (prompt.map { " '\($0)'" } ?? "")]
        case let .resumeClaude(uuid):
            args = ["-l", "-c", "exec claude --resume \(uuid)"]
        case .shell:
            args = ["-l"]
        }
        return Self(executable: executable, args: args, currentDirectory: folder)
    }

    /// Lowercase canonical UUID only (same as Go's `uuidRe`): the id is
    /// interpolated into a shell command, so nothing else may pass.
    package static func isValidSessionID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count == 36 else { return false }
        return scalars.enumerated().allSatisfy { index, scalar in
            if [8, 13, 18, 23].contains(index) { return scalar == "-" }
            return ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
        }
    }

    package static func workOnTargetPrompt(targetID: Int64) -> String {
        "Work on target #\(targetID) using the watchtower-project skill."
    }

    /// The terminal pane's line after the session ends. 127 is the shell's
    /// "command not found": `exec claude` found no `claude` on the login
    /// shell's PATH, which a bare exit code would not tell the owner.
    package static func exitMessage(code: Int32?) -> String {
        switch code {
        case 127?:
            "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart."
        case let code?:
            "Claude Code exited (code \(code))."
        case nil:
            "Claude Code exited."
        }
    }
}
