import Darwin
import Foundation

/// Open output on the Workchat's agent-finished row (spec 2026-11-24-workchat-polish §3): the task's output file is
/// read for the read-only viewer only when, every symlink resolved, it is a regular file of the row's own Claude Code
/// session — inside its temp dir (`<base>/claude-<uid>/<project>/<session id>/…`, a background command's output) or
/// its subagent transcripts (`~/.claude/projects/<project>/<session id>/subagents/…`, where an agent's
/// `tasks/<id>.output` link points: it opens as raw JSONL), `<project>` being the one the feed reads the session's
/// transcript from. Anything else is revealed in Finder.
package enum TaskOutputFile {
    package enum Outcome: Equatable, Sendable {
        /// The first `limit` bytes as text; `cut` when the file is longer.
        case text(String, cut: Bool)
        /// Not inside the session's temp dir: reveal it in Finder.
        case reveal
        /// Gone, or inside but unreadable or not a regular file.
        case unreadable
    }

    /// The most of an output file the viewer shows (an agent's output is its whole transcript).
    package static let limit = 256 * 1024

    /// The temp roots Claude Code may write under, symlink-resolved and deduplicated: `/tmp`, the OS temp dir and
    /// `$CLAUDE_CODE_TMPDIR` when set — the same rules as Go's `scratchBases` in
    /// `internal/sessioncleanup/ownership.go`. A relative base, or one that does not resolve, is left out.
    package static func tempBases(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        osTemp: String = NSTemporaryDirectory()
    ) -> [String] {
        var candidates = ["/tmp", osTemp]
        if let dir = environment["CLAUDE_CODE_TMPDIR"], !dir.isEmpty { candidates.append(dir) }
        var out: [String] = []
        for candidate in candidates {
            guard candidate.hasPrefix("/"), let resolved = realPath(candidate), !out.contains(resolved) else { continue }
            out.append(resolved)
        }
        return out
    }

    /// Claude Code's directory as the session feed reads it: `~/.claude`, never `$CLAUDE_CONFIG_DIR` (Go's
    /// `agentlog.DefaultClaudeDir`, review-rules §5); nil when the home directory is not absolute.
    package static func defaultClaudeDir(home: String = NSHomeDirectory()) -> String? {
        home.hasPrefix("/") ? (home as NSString).appendingPathComponent(".claude") : nil
    }

    /// Reads `path` for the viewer when it resolves inside the session's temp dir under one of `bases`, or inside
    /// `<projectDir>/<session id>/subagents/` when `projectDir` (the directory the feed read the conversation's transcript from) is a
    /// project of `claudeDir`'s `projects` — both compared fully resolved, so a linked `projects` still matches.
    package static func read(
        _ path: String,
        claudeSessionID: String?,
        projectDir: String?,
        uid: uid_t = getuid(),
        bases: [String] = tempBases(),
        claudeDir: String? = defaultClaudeDir(),
        limit: Int = limit
    ) -> Outcome {
        guard let claudeSessionID, !claudeSessionID.isEmpty, path.hasPrefix("/") else { return .reveal }
        guard let resolved = realPath(path) else { return .unreadable }
        let subagents = subagentsRoot(projectDir: projectDir, claudeDir: claudeDir).map { $0 + [claudeSessionID, "subagents"] }
        let inside = { (file: String) in
            Self.inside(file, sessionID: claudeSessionID, uid: uid, bases: bases)
                || subagents.map { root in
                    let parts = components(file)
                    return parts.count > root.count && Array(parts.prefix(root.count)) == root
                } == true
        }
        guard inside(resolved) else { return .reveal }
        // Opened without following a last-component link and without blocking (a FIFO); the descriptor's own path
        // is checked again, so a directory swapped for a link between the two steps is still caught.
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let opened = descriptorPath(fd), inside(opened)
        else { return .unreadable }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return .unreadable
        }
        // Lossy on purpose: the cut can split a character.
        // swiftlint:disable:next optional_data_string_conversion
        return .text(String(decoding: data.prefix(limit), as: UTF8.self), cut: data.count > limit)
    }

    /// `path` sits in `<base>/claude-<uid>/<project>/<sessionID>/…` of a base (both already resolved).
    private static func inside(_ path: String, sessionID: String, uid: uid_t, bases: [String]) -> Bool {
        let parts = components(path)
        return bases.contains { base in
            let root = components(base) + ["claude-\(uid)"]
            return parts.count >= root.count + 3 && Array(parts.prefix(root.count)) == root
                && parts[root.count + 1] == sessionID
        }
    }

    /// The resolved project dir as components, when it is a direct child of the resolved `<claudeDir>/projects`.
    private static func subagentsRoot(projectDir: String?, claudeDir: String?) -> [String]? {
        guard let projectDir, projectDir.hasPrefix("/"), let claudeDir, claudeDir.hasPrefix("/"),
              let projects = realPath((claudeDir as NSString).appendingPathComponent("projects")),
              let project = realPath(projectDir)
        else { return nil }
        let (root, parts) = (components(projects), components(project))
        return parts.count == root.count + 1 && Array(parts.prefix(root.count)) == root ? parts : nil
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func descriptorPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }
}
