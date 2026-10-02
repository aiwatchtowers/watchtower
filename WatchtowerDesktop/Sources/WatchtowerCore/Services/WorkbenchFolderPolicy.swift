import Foundation

/// Folder checks for the New-project flow (spec §6.2). The embedded terminal
/// runs Claude Code as Watchtower's child, so macOS attributes its file access
/// to Watchtower: a folder under one of these locations makes the first file
/// read raise a TCC prompt naming Watchtower. The POC warns before creating.
package enum WorkbenchFolderPolicy {
    package static let tccSensitiveLocations = ["Documents", "Desktop", "Downloads", "Library/CloudStorage"]

    /// The `~/…` location `path` lies in (or is), or nil. Both paths must be
    /// absolute and symlink-resolved by the caller.
    package static func tccSensitiveLocation(path: String, home: String) -> String? {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        for location in tccSensitiveLocations {
            let root = base + "/" + location
            if path == root || path.hasPrefix(root + "/") {
                return "~/" + location
            }
        }
        return nil
    }
}
