import Foundation

/// Whether Claude Code has a transcript for a session id, so a Restart can
/// `--resume` it. Claude Code writes `<config>/projects/<encoded cwd>/<uuid>.jsonl`
/// only once the session is used; a session the owner never typed into, or
/// whose first start failed, has none, and `--resume` would refuse it forever.
package enum ClaudeTranscript {
    /// Always `~/.claude`, never `CLAUDE_CONFIG_DIR` — the same rule as Go
    /// `defaultTerminalClaudeDir` (cmd/terminal.go), a dual path. An env
    /// override could point the app at a TCC-protected folder, and the app's
    /// environment need not match the login shell the embedded claude runs in.
    package static var defaultConfigDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    /// Looks in every project directory under `<configDir>/projects`. An
    /// invalid id is never used in a path and has no transcript.
    package static func exists(
        sessionID: String,
        configDir: String = defaultConfigDir,
        listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard TerminalLaunch.isValidSessionID(sessionID) else { return false }
        let projects = (configDir as NSString).appendingPathComponent("projects")
        return listDirectory(projects).contains { dir in
            fileExists(((projects as NSString).appendingPathComponent(dir) as NSString)
                .appendingPathComponent("\(sessionID).jsonl"))
        }
    }
}
