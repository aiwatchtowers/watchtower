import Foundation
import Observation

/// One entry of a listed directory.
struct CodeFileEntry: Hashable, Sendable {
    let name: String
    /// Relative to the tree's root; "" is the root itself.
    let relPath: String
    let isDirectory: Bool
}

/// A workbench folder as a lazily listed tree: a directory is read when it
/// is first expanded and re-read when FSEvents reports a change inside it.
@MainActor
@Observable
final class CodeFileTree {
    /// Never listed (and their changes ignored): VCS and build output that
    /// would bury the source.
    nonisolated static let hiddenNames: Set<String> = [
        ".git", ".build", "node_modules", ".DS_Store", ".swiftpm", "DerivedData", ".idea", ".worktrees"
    ]

    struct Row: Hashable {
        let entry: CodeFileEntry
        let depth: Int
        let isExpanded: Bool
    }

    let root: URL
    private(set) var expanded: Set<String> = [""]
    private(set) var listings: [String: [CodeFileEntry]] = [:]
    /// A directory that could not be read, by its path ("" = the folder).
    private(set) var errors: [String: String] = [:]

    init(root: URL) {
        self.root = root
    }

    /// The visible rows, depth-first: the children of every expanded
    /// directory under its row.
    var rows: [Row] {
        var out: [Row] = []
        append(children: "", depth: 0, into: &out)
        return out
    }

    private func append(children dir: String, depth: Int, into out: inout [Row]) {
        for entry in listings[dir] ?? [] {
            let open = entry.isDirectory && expanded.contains(entry.relPath)
            out.append(Row(entry: entry, depth: depth, isExpanded: open))
            if open { append(children: entry.relPath, depth: depth + 1, into: &out) }
        }
    }

    func toggle(_ dir: String) {
        if expanded.contains(dir) {
            expanded.remove(dir)
        } else {
            expand(dir)
        }
    }

    /// Opens `dir` and every folder above it (a new entry is created there).
    func expand(_ dir: String) {
        var path = dir
        while !path.isEmpty {
            if !expanded.contains(path) {
                expanded.insert(path)
                load(path)
            }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    func collapseAll() {
        expanded = [""]
    }

    /// Re-reads the listed directories among `directories`; the rest are
    /// read when next expanded.
    func refresh(directories: Set<String>) {
        for dir in directories where listings[dir] != nil {
            load(dir)
        }
    }

    func reloadAll() {
        listings.keys.forEach(load)
    }

    func loadIfNeeded() {
        if listings[""] == nil { load("") }
    }

    private func load(_ dir: String) {
        let url = dir.isEmpty ? root : root.appendingPathComponent(dir)
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )
            let entries = urls.compactMap { child -> CodeFileEntry? in
                let name = child.lastPathComponent
                guard !Self.hiddenNames.contains(name) else { return nil }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return CodeFileEntry(name: name, relPath: dir.isEmpty ? name : dir + "/" + name, isDirectory: isDirectory)
            }
            listings[dir] = entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            errors[dir] = nil
        } catch {
            if dir.isEmpty {
                // The folder itself: say so instead of showing an empty tree.
                listings[""] = []
                errors[""] = (error as NSError).code == NSFileReadNoSuchFileError
                    ? "The workbench folder no longer exists." : error.localizedDescription
            } else if (error as NSError).code == NSFileReadNoSuchFileError {
                // A directory that vanished (deleted by the agent) drops out.
                listings[dir] = nil
                expanded.remove(dir)
                errors[dir] = nil
            } else {
                listings[dir] = []
                errors[dir] = error.localizedDescription
            }
        }
    }
}
