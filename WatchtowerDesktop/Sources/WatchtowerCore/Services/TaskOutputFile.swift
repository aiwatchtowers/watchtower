import Darwin
import Foundation

/// Open output on the Workchat's agent-finished row (spec 2026-11-24-workchat-polish §3): the task's output file is
/// read for the read-only viewer only when, every symlink resolved, it is a regular file inside the session's own
/// Claude Code temp dir (`<base>/claude-<uid>/<project>/<claude session id>/…`); anything else is revealed in Finder.
/// An agent's `.output` is a symlink to its transcript JSONL in the same dir, so it opens (as raw JSONL).
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
    /// `internal/sessioncleanup/ownership.go`. A base that does not resolve is left out.
    package static func tempBases(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        osTemp: String = NSTemporaryDirectory()
    ) -> [String] {
        var candidates = ["/tmp", osTemp]
        if let dir = environment["CLAUDE_CODE_TMPDIR"], !dir.isEmpty { candidates.append(dir) }
        var out: [String] = []
        for candidate in candidates {
            guard let resolved = realPath(candidate), !out.contains(resolved) else { continue }
            out.append(resolved)
        }
        return out
    }

    /// Reads `path` for the viewer when it resolves inside the session's temp dir under one of `bases`.
    package static func read(
        _ path: String,
        claudeSessionID: String?,
        uid: uid_t = getuid(),
        bases: [String] = tempBases(),
        limit: Int = limit
    ) -> Outcome {
        guard let claudeSessionID, !claudeSessionID.isEmpty, path.hasPrefix("/") else { return .reveal }
        guard let resolved = realPath(path) else { return .unreadable }
        guard inside(resolved, sessionID: claudeSessionID, uid: uid, bases: bases) else { return .reveal }
        // Opened without following a last-component link and without blocking (a FIFO); the descriptor's own path
        // is checked again, so a directory swapped for a link between the two steps is still caught.
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let opened = descriptorPath(fd), inside(opened, sessionID: claudeSessionID, uid: uid, bases: bases)
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
