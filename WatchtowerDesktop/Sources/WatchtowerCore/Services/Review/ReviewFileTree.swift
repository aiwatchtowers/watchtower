import Foundation

/// The Branch review's changed files as a folder tree (#960). Pure: built from
/// the diff's paths (a renamed file is listed once, under its new path).
/// Single-child folder chains are compacted into one `a/b/c` folder; folders
/// come before files, each group in localized standard order.
package struct ReviewFileTree: Sendable {
    package indirect enum Node: Equatable, Sendable {
        case folder(name: String, path: String, children: [Self])
        case file(path: String)
    }

    package static func build(_ paths: [String]) -> [Node] {
        var root = Self.Directory()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            root.insert(parts[...], fullPath: path)
        }
        return nodes(of: root, prefix: "")
    }

    private struct Directory {
        var folders: [String: Self] = [:]
        var files: [String: String] = [:] // name -> full path

        mutating func insert(_ parts: ArraySlice<String>, fullPath: String) {
            guard let head = parts.first else { return }
            if parts.count == 1 {
                files[head] = fullPath
            } else {
                folders[head, default: Self()].insert(parts.dropFirst(), fullPath: fullPath)
            }
        }
    }

    private static func nodes(of directory: Directory, prefix: String) -> [Node] {
        let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        let folderNodes = directory.folders.sorted { byName($0.key, $1.key) }.map { entry -> Node in
            var name = entry.key
            var current = entry.value
            // Compact a chain of folders that hold nothing but one folder.
            while current.files.isEmpty, current.folders.count == 1, let (next, child) = current.folders.first {
                name += "/" + next
                current = child
            }
            let path = prefix + name
            return .folder(name: name, path: path, children: nodes(of: current, prefix: path + "/"))
        }
        let fileNodes = directory.files.sorted { byName($0.key, $1.key) }.map { Node.file(path: $0.value) }
        return folderNodes + fileNodes
    }
}
