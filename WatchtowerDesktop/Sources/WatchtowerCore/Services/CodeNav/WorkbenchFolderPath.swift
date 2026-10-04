import Darwin
import Foundation

/// A file of a workbench folder named by a link (an answer's `path:line`, a
/// terminal ⌘-click, a reopened question's file), resolved without ever
/// touching the disk outside the folder: each component is looked at with
/// `lstat`, and a symlink is followed only after its target, read with
/// `readlink`, is checked by its text to stay inside the folder. A `stat`,
/// `realpath` or read of a symlink's target in `~/Desktop` or `~/Documents`
/// could raise a macOS privacy prompt attributed to Watchtower (ruling R53,
/// board #361). Pure apart from the `FileSystem` seam.
package enum WorkbenchFolderPath {
    package enum EntryKind: Equatable, Sendable {
        case file
        case directory
        case symlink
        case other
    }

    /// The disk lookups `resolve` makes, a seam for tests. Every path given
    /// to `entryKind` and `linkTarget` lies inside the folder.
    package struct FileSystem: Sendable {
        /// `lstat`: what the entry itself is; nil when it does not exist.
        package var entryKind: @Sendable (String) -> EntryKind?
        /// `readlink`: a symlink's target as written.
        package var linkTarget: @Sendable (String) -> String?
        /// The folder itself with its symlinks resolved.
        package var realPath: @Sendable (String) -> String?

        package init(
            entryKind: @escaping @Sendable (String) -> EntryKind?,
            linkTarget: @escaping @Sendable (String) -> String?,
            realPath: @escaping @Sendable (String) -> String?
        ) {
            self.entryKind = entryKind
            self.linkTarget = linkTarget
            self.realPath = realPath
        }

        package static let live = Self(
            entryKind: { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { return nil }
                switch info.st_mode & S_IFMT {
                case S_IFREG: return .file
                case S_IFDIR: return .directory
                case S_IFLNK: return .symlink
                default: return .other
                }
            },
            linkTarget: { path in
                try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            },
            realPath: { path in
                guard let resolved = realpath(path, nil) else { return nil }
                defer { free(resolved) }
                return String(cString: resolved)
            }
        )
    }

    /// Symlinks followed before giving up (the kernel's own limit).
    private static let maxLinks = 32

    /// The regular file `relativePath` names inside `folder`, as a path
    /// relative to the folder's real path with every symlink resolved; nil
    /// when it is missing, not a regular file, or leaves the folder — by
    /// `..` or through a symlink, which is refused before its target is
    /// looked at. `folderRealPath` is the folder's resolved path when the
    /// caller has it (nil = looked up here).
    package static func resolve(
        _ relativePath: String, folder: String, folderRealPath: String? = nil, fileSystem: FileSystem = .live
    ) -> String? {
        guard !relativePath.hasPrefix("/"), let root = folderRealPath ?? fileSystem.realPath(folder) else { return nil }
        let roots = [lexicallyNormalized(root), lexicallyNormalized(folder)]
        var pending = components(relativePath)
        // Components of `root` already resolved: never a symlink.
        var resolved: [Substring] = []
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            switch part {
            case ".":
                continue
            case "..":
                // Out of the folder by `..`: refused.
                guard !resolved.isEmpty else { return nil }
                resolved.removeLast()
                continue
            default:
                break
            }
            let current = path(root, resolved + [part])
            switch fileSystem.entryKind(current) {
            case .symlink:
                links += 1
                guard links <= maxLinks, let target = fileSystem.linkTarget(current) else { return nil }
                if target.hasPrefix("/") {
                    // Inside either spelling of the folder, by its text only.
                    let absolute = lexicallyNormalized(target)
                    guard let inside = roots.lazy.compactMap({ relative(absolute, to: $0) }).first else { return nil }
                    resolved = []
                    pending = components(inside) + pending
                } else {
                    pending = components(target) + pending
                }
            case .directory:
                resolved.append(part)
            case .file:
                // A file is the last component, or nothing is.
                guard pending.allSatisfy({ $0 == "." }) else { return nil }
                resolved.append(part)
                return resolved.joined(separator: "/")
            case .other, nil:
                return nil
            }
        }
        return nil
    }

    // MARK: - Private

    private static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private static func path(_ root: String, _ parts: [Substring]) -> String {
        ([root.hasSuffix("/") ? String(root.dropLast()) : root] + parts.map(String.init)).joined(separator: "/")
    }

    /// `path` relative to `root` ("" for the root itself), or nil when it
    /// is not under it.
    private static func relative(_ path: String, to root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// `.` and `..` folded and repeated slashes dropped, by the text alone.
    package static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in components(path) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
