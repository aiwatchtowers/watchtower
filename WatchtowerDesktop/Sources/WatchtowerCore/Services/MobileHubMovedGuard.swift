import Foundation

/// The downgrade guard of the Swift phone hub (go hub spec §12.1, "never two
/// hubs"): a newer Watchtower whose Go hub adopted this Mac's hub leaves
/// `MobileHub/` with one note, `MOVED`, holding `hub_impl=go\nmoved_to=<hub dir>\n`.
/// An older app that finds it starts no Swift hub: it opens no `hubstate.db`,
/// reads no Keychain item and starts no transport, and Settings → Mobile shows
/// `message`. The note's other lines are never read.
public enum MobileHubMovedGuard {
    public static let noteName = "MOVED"
    public static let message = "Mobile is run by a newer Watchtower"
    /// The line that marks the move; a note without it is ignored.
    static let implLine = "hub_impl=go"
    /// The note is two short lines; anything past this is not read.
    static let maxNoteBytes = 4096

    /// Thrown by the live hub storage instead of opening anything once Mobile moved.
    public struct Moved: Error, Equatable {
        public init() {}
    }

    /// Whether `mobileHubDir/MOVED` is a regular file with the line `hub_impl=go`.
    public static func isMoved(mobileHubDir: URL, fileManager: FileManager = .default) -> Bool {
        let note = mobileHubDir.appendingPathComponent(noteName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: note.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let handle = try? FileHandle(forReadingFrom: note) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxNoteBytes),
              let text = String(bytes: data, encoding: .utf8) else { return false }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { $0 == implLine }
    }
}
