import Foundation

/// Whether Claude Code has a transcript for a session id, so a Restart can
/// `--resume` it. Claude Code writes `<config>/projects/<encoded cwd>/<uuid>.jsonl`
/// only once the session is used; a session the owner never typed into, or
/// whose first start failed, has none, and `--resume` would refuse it forever.
package enum ClaudeTranscript {
    /// `~/.claude`, or `CLAUDE_CONFIG_DIR` when the owner set one.
    package static var defaultConfigDir: String {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
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
