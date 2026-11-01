import Darwin
import Foundation

/// The downgrade guard of the Swift phone hub (go hub spec §12.1, "never two
/// hubs"): a newer Watchtower whose Go hub adopted this Mac's hub leaves
/// `MobileHub/` with one note, `MOVED`, holding `hub_impl=go\nmoved_to=<hub dir>\n`.
/// An older app that finds it starts no Swift hub: it opens no `hubstate.db`,
/// reads no Keychain item and starts no transport, and Settings → Mobile shows
/// `message`.
public enum MobileHubMovedGuard {
    public static let noteName = "MOVED"
    public static let message = "Mobile is run by a newer Watchtower"
    /// The line that marks the move; a readable note without it is ignored.
    static let implLine = "hub_impl=go"
    /// The note is two short lines; nothing past this is read.
    static let maxNoteBytes = 4096

    /// Thrown by the live hub storage instead of opening anything once Mobile moved.
    public struct Moved: Error, Equatable {
        public init() {}
    }

    /// Whether Mobile moved to a newer Watchtower. Fails closed: "not moved"
    /// only when nothing exists at `MOVED` (by `lstat`), or when it is a
    /// readable regular file whose lines in the first `maxNoteBytes` are valid
    /// UTF-8 and none of them is `hub_impl=go`. Anything else at that name
    /// counts as moved, because only a newer app writes it: a symlink (never
    /// followed), a directory or other non-regular file, a file that cannot be
    /// opened or read, or a line that is not UTF-8. Lines split on LF, with a
    /// trailing CR and surrounding spaces trimmed. A last line cut by the cap
    /// (possibly mid-character) is skipped.
    public static func isMoved(mobileHubDir: URL) -> Bool {
        let path = mobileHubDir.appendingPathComponent(noteName, isDirectory: false).path
        var info = stat()
        if lstat(path, &info) != 0 { return errno != ENOENT && errno != ENOTDIR }
        guard info.st_mode & S_IFMT == S_IFREG else { return true }
        guard let bytes = readHead(path) else { return true }
        var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if bytes.count == maxNoteBytes, bytes.last != UInt8(ascii: "\n") { lines.removeLast() }
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))
        for line in lines {
            guard let text = String(bytes: line, encoding: .utf8) else { return true }
            if text.trimmingCharacters(in: trim) == implLine { return true }
        }
        return false
    }

    /// The first `maxNoteBytes` of the regular file at `path`, never following
    /// a symlink; nil when it cannot be opened or read.
    private static func readHead(_ path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: maxNoteBytes)
        var count = 0
        while count < maxNoteBytes {
            let got = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress.map { $0 + count }, maxNoteBytes - count)
            }
            if got == 0 { break }
            if got < 0 {
                if errno == EINTR { continue }
                return nil
            }
            count += got
        }
        return Array(buffer[..<count])
    }
}
