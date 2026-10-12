import Foundation

/// Whether Codex has a rollout (its transcript) for a session id, so a
/// relaunch can `codex resume` it (spec 2026-10-12 §7). Rollouts live at
/// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`. Go twin:
/// `findCodexRollout` (internal/terminal/codex_rollout.go), a dual path.
package enum CodexRollout {
    /// `$CODEX_HOME` when it is an absolute path, else `~/.codex` (Codex's own
    /// rule; Go `defaultTerminalCodexHome`).
    package static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CODEX_HOME"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
    }

    /// The stored path (`agent_transcript_path`) when it is an absolute
    /// regular file named for this session; else any date folder under
    /// `codexHome/sessions`. An invalid id is never used in a path.
    package static func exists(sessionID: String, storedPath: String?, codexHome: URL) -> Bool {
        guard TerminalLaunch.isValidSessionID(sessionID) else { return false }
        if let storedPath, isRollout(storedPath, of: sessionID), isRegularFile(storedPath) { return true }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true).path
        for year in subdirectories(of: sessions) {
            for month in subdirectories(of: year) {
                for day in subdirectories(of: month) where entries(of: day).contains(where: { isRolloutName($0, of: sessionID) }) {
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

    /// A missing folder lists nothing.
    private static func entries(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private static func subdirectories(of path: String) -> [String] {
        entries(of: path).map { (path as NSString).appendingPathComponent($0) }.filter { child in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
