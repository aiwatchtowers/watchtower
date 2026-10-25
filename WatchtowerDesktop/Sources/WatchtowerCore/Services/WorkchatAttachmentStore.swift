import Foundation

/// Where the Workchat keeps what the owner pastes: bytes land under
/// `<root>/<sessionID>/`, and the agent gets the path (#711). Nothing here is
/// a database row. The files are the owner's only (0600 in a 0700 folder)
/// and live as long as their session (#604 S9): a session's exit removes its
/// folder, and the launch sweep removes the folder of every session that is
/// not running.
package struct WorkchatAttachmentStore {
    /// `<workspace>/workchat-attachments`.
    package let root: URL
    private let now: () -> Date
    private let fileManager: FileManager

    package init(root: URL, now: @escaping () -> Date = Date.init, fileManager: FileManager = .default) {
        self.root = root
        self.now = now
        self.fileManager = fileManager
    }

    /// Writes `data` as `<root>/<sessionID>/<yyyyMMdd-HHmmss UTC>-<n>.<ext>`
    /// (0600, the folders 0700) and returns the file; `n` is the first number
    /// whose name is free, and the extension is `name`'s.
    package func save(_ data: Data, name: String, sessionID: Int64) throws -> URL {
        let folder = root.appendingPathComponent(String(sessionID), isDirectory: true)
        let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: owner)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: owner)
        let stamp = Self.stamp(now())
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let file = folder.appendingPathComponent("\(stamp)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fileManager.fileExists(atPath: file.path) {
                // Created 0600 (no window with wider bits); a name taken
                // meanwhile fails instead of overwriting.
                guard fileManager.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
                }
                return file
            }
            n += 1
        }
    }

    /// Removes the folder of every session not in `live`, whatever its age.
    /// Best effort: a failure is logged and the rest goes on.
    package func sweep(keepingSessions live: Set<Int64>) {
        let folders: [URL]
        do {
            guard fileManager.fileExists(atPath: root.path) else { return }
            folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            NSLog("WorkchatAttachmentStore: cannot list %@: %@", root.path, String(describing: error))
            return
        }
        for folder in folders {
            guard let id = Int64(folder.lastPathComponent), !live.contains(id) else { continue }
            remove(folder)
        }
    }

    /// Removes one session's folder (its run ended). A missing one is fine.
    package func remove(sessionID: Int64) {
        remove(root.appendingPathComponent(String(sessionID), isDirectory: true))
    }

    private func remove(_ folder: URL) {
        do {
            try fileManager.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            NSLog("WorkchatAttachmentStore: removing %@ failed: %@", folder.path, String(describing: error))
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
