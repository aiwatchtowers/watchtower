import Foundation

/// Whether Codex has a rollout (its transcript) for a session id, so a
/// relaunch can `codex resume` it (spec 2026-10-12 §7). Rollouts live at
/// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`. Go twin:
/// `findCodexRollout` (internal/terminal/codex_rollout.go), a dual path.
package enum CodexRollout {
    /// `$CODEX_HOME` when it is an absolute path, else `~/.codex` (Codex's own
    /// rule; Go `defaultTerminalCodexHome`). The environment is the login
    /// shell's, the one the launched Codex reads (spec 2026-10-12 §7), once
    /// the launch-time prewarm resolved it; before that the app's own — the
    /// MainActor never waits on the login shell
    /// (`Constants.resolvedEnvironmentIfReady`).
    package static func home(environment: [String: String] = Constants.resolvedEnvironmentIfReady()) -> URL {
        if let dir = environment["CODEX_HOME"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
    }

    /// The stored path (`agent_transcript_path`) when it is an absolute
    /// regular file named for this session; else any date folder under
    /// `codexHome/sessions`. An invalid id is never used in a path. A
    /// missing folder lists nothing; a folder that exists but could not be
    /// listed (no permission, say) throws, so "could not look" is never
    /// read as "no rollout".
    package static func exists(sessionID: String, storedPath: String?, codexHome: URL) throws -> Bool {
        guard TerminalLaunch.isValidSessionID(sessionID) else { return false }
        if let storedPath, isRollout(storedPath, of: sessionID), isRegularFile(storedPath) { return true }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true).path
        for year in try subdirectories(of: sessions) {
            for month in try subdirectories(of: year) {
                for day in try subdirectories(of: month)
                    where try entries(of: day).contains(where: { isRolloutName($0, of: sessionID) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Go `isRolloutOf`: a stored path never names an arbitrary file.
    static func isRollout(_ path: String, of sessionID: String) -> Bool {
        path.hasPrefix("/") && isRolloutName((path as NSString).lastPathComponent, of: sessionID)
    }

    /// `rollout-*-<id>.jsonl`.
    private static func isRolloutName(_ name: String, of sessionID: String) -> Bool {
        let prefix = "rollout-", suffix = "-\(sessionID).jsonl"
        return name.count >= prefix.count + suffix.count && name.hasPrefix(prefix) && name.hasSuffix(suffix)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// A missing folder lists nothing; any other failure throws.
    private static func entries(of path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    private static func subdirectories(of path: String) throws -> [String] {
        try entries(of: path).map { (path as NSString).appendingPathComponent($0) }.filter { child in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
