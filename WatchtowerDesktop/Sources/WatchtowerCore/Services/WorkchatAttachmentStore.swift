import Foundation

/// Where the Workchat keeps what the owner pastes: bytes land under
/// `<root>/<sessionID>/`, and the agent gets the path (#711). Nothing here is
/// a database row; a launch sweep removes old files.
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
    /// and returns the file; `n` is the first number whose name is free, and
    /// the extension is `name`'s.
    package func save(_ data: Data, name: String, sessionID: Int64) throws -> URL {
        let folder = root.appendingPathComponent(String(sessionID), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.stamp(now())
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let file = folder.appendingPathComponent("\(stamp)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fileManager.fileExists(atPath: file.path) {
                try data.write(to: file, options: .withoutOverwriting)
                return file
            }
            n += 1
        }
    }

    /// Removes files older than `olderThan` from the folders of sessions not
    /// in `live`, and a folder left empty. Best effort: a failure is logged
    /// and the rest goes on.
    package func sweep(olderThan age: TimeInterval = 7 * 86_400, keepingSessions live: Set<Int64>) {
        let cutoff = now().addingTimeInterval(-age)
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
            do {
                let files = try fileManager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
                )
                var left = files.count
                for file in files {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    guard let modified, modified < cutoff else { continue }
                    try fileManager.removeItem(at: file)
                    left -= 1
                }
                if left == 0 { try fileManager.removeItem(at: folder) }
            } catch {
                NSLog("WorkchatAttachmentStore: sweep of %@ failed: %@", folder.path, String(describing: error))
            }
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
