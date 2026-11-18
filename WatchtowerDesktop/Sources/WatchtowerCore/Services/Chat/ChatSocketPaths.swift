import CryptoKit
import Foundation

/// The chat engine's socket paths, the twin of Go's `chatengine.SocketPath`
/// and `SessionSocketPath` (both read
/// `internal/chatengine/testdata/socket_paths.json`): `<workspace>/chat.sock`
/// and `<workspace>/chatengine/sessions/<conversation>.sock`, or — when a path
/// is longer than a socket path may be — the same names under
/// `<tempDir>/wtchat-<12 hex of sha256(workspace)>`. Both folders are absolute;
/// a trailing slash is ignored.
public enum ChatSocketPaths {
    /// The longest socket path: `sun_path` holds 104 bytes on macOS, the
    /// terminating NUL included.
    public static let maxSocketPath = 103
    public static let socketName = "chat.sock"

    public static func socketPath(workspace: String, tempDir: String, maxLength: Int = maxSocketPath) -> String {
        let primary = join(workspace, socketName)
        if primary.utf8.count <= maxLength { return primary }
        return join(fallbackDir(workspace: workspace, tempDir: tempDir), socketName)
    }

    public static func sessionSocketPath(
        workspace: String,
        tempDir: String,
        conversation: Int64,
        maxLength: Int = maxSocketPath
    ) -> String {
        let name = "\(conversation).sock"
        let primary = join(join(join(workspace, "chatengine"), "sessions"), name)
        if primary.utf8.count <= maxLength { return primary }
        return join(join(fallbackDir(workspace: workspace, tempDir: tempDir), "sessions"), name)
    }

    static func fallbackDir(workspace: String, tempDir: String) -> String {
        let digest = SHA256.hash(data: Data(trimSlash(workspace).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return join(tempDir, "wtchat-" + String(hex.prefix(12)))
    }

    /// `base/name` with `base`'s trailing slashes dropped (Go's filepath.Join
    /// on clean absolute folders).
    static func join(_ base: String, _ name: String) -> String {
        let trimmed = trimSlash(base)
        return trimmed == "/" ? "/" + name : trimmed + "/" + name
    }

    static func trimSlash(_ path: String) -> String {
        var p = Substring(path)
        while p.count > 1, p.hasSuffix("/") { p = p.dropLast() }
        return String(p)
    }
}
