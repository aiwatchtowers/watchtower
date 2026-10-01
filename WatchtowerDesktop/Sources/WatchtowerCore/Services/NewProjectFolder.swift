import Foundation

/// The New Project… flow's folder step: the owner names a folder that may not
/// exist yet. `check` decides — without touching the disk — whether it will be
/// created or an existing empty folder reused, and refuses anything else;
/// `prepare` then makes it. The caller runs the TCC-location warning between
/// the two, so "Choose another folder" leaves nothing behind on disk.
package enum NewProjectFolder {
    package enum Plan: Equatable {
        case create
        case reuseEmpty
    }

    package enum Failure: Error, Equatable, LocalizedError {
        case notADirectory(path: String)
        case notEmpty(path: String)
        case unreadable(path: String, reason: String)
        case createFailed(path: String, reason: String)

        package var errorDescription: String? {
            switch self {
            case let .notADirectory(path):
                "\(path) already exists and is not a folder."
            case let .notEmpty(path):
                "\(path) already exists and is not empty — use Add Existing Folder… to make a project of it."
            case let .unreadable(path, reason):
                "Could not read \(path): \(reason)"
            case let .createFailed(path, reason):
                "Could not create \(path): \(reason)"
            }
        }
    }

    /// The panel's starting folder: `~/Projects` when it exists, else home.
    package static func defaultParent(home: URL, fileManager: FileManager = .default) -> URL {
        let projects = home.appendingPathComponent("Projects", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue {
            return projects
        }
        return home
    }

    /// `url` with its parent symlink-resolved: the folder itself may not exist
    /// yet, so resolving the whole path would leave a symlinked parent (and so
    /// the TCC-location check) unresolved.
    package static func resolved(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    /// Read-only: what `prepare` will do with `url`, or why it must not.
    package static func check(_ url: URL, fileManager: FileManager = .default) throws -> Plan {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return .create }
        guard isDir.boolValue else { throw Failure.notADirectory(path: url.path) }
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: url.path)
        } catch {
            throw Failure.unreadable(path: url.path, reason: error.localizedDescription)
        }
        // Finder's `.DS_Store` alone does not make a folder the owner's content.
        guard entries.allSatisfy({ $0 == ".DS_Store" }) else { throw Failure.notEmpty(path: url.path) }
        return .reuseEmpty
    }

    /// Re-checks (the disk may have changed while the warning was up) and
    /// creates the folder when it does not exist. Returns the plan it followed.
    @discardableResult
    package static func prepare(_ url: URL, fileManager: FileManager = .default) throws -> Plan {
        let plan = try check(url, fileManager: fileManager)
        guard plan == .create else { return plan }
        do {
            // Not intermediate: the parent is the folder the owner picked.
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw Failure.createFailed(path: url.path, reason: error.localizedDescription)
        }
        return plan
    }
}
