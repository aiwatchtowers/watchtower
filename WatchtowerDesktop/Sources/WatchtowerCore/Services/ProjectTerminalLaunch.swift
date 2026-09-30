import Foundation

/// How the Projects terminal starts Claude Code (spec §6.2): the owner's own
/// login shell, so `PATH` and `claude`'s auth are exactly theirs, `exec`ing
/// `claude` in the project folder. A new project gets the fixed first-run
/// prompt — never owner data on the command line.
package struct ProjectTerminalLaunch: Equatable, Sendable {
    package static let firstRunPrompt = "Set up this Watchtower project using the watchtower-project skill."
    package static let fallbackShell = "/bin/zsh"

    package let executable: String
    package let args: [String]
    package let currentDirectory: String

    package static func make(shell: String?, folder: String, firstRun: Bool) -> Self {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let command = firstRun ? "exec claude '\(firstRunPrompt)'" : "exec claude"
        return Self(executable: executable, args: ["-l", "-c", command], currentDirectory: folder)
    }
}
