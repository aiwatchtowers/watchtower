import Foundation

/// Settings → Rename… on a connected account: `watchtower <source> rename
/// <id> <name>`. The name an account gets at connect is automatic (Go,
/// `internal/db/account_labels.go`); this is how the owner changes it. Shared
/// by every account view model — slack, jira, google, imap (any mailbox, IMAP
/// or Outlook) and caldav (CalDAV and ICS).
package enum AccountRename {
    /// The CLI args. `--` ends the flags so a name starting with "-" is taken
    /// as the name, not as an unknown flag. Pure, for tests.
    package static func args(source: String, id: Int, name: String) -> [String] {
        [source, "rename", "--", String(id), name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Runs the rename; nil on success, else the message to show the owner.
    /// An empty name is refused here as the CLI would refuse it.
    package static func run(source: String, id: Int, name: String, cliPath: String?) async -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The name must not be empty."
        }
        guard let cliPath else { return "Watchtower CLI not found" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args(source: source, id: id, name: name)
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        let result = await ProcessPipes.run(process).trimmed
        if result.exitCode == 0 { return nil }
        return result.stderr.isEmpty
            ? "Rename failed (exit \(result.exitCode))"
            : String(result.stderr.prefix(200))
    }
}
