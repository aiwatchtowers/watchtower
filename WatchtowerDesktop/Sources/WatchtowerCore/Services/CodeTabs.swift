import Foundation

/// The code viewer's open file tabs of one workbench (POC): their order, the
/// active one and at most one preview tab — the tab a single click in the
/// FILES tree opens and the next single click replaces. A double click or
/// the first edit keeps it (`pin`). Paths are relative to the workbench
/// folder. Pure value type, persisted as JSON per workbench.
package struct CodeTabs: Codable, Equatable, Sendable {
    package struct Tab: Codable, Equatable, Hashable, Sendable {
        package let path: String
        package var isPreview: Bool

        package init(path: String, isPreview: Bool) {
            self.path = path
            self.isPreview = isPreview
        }
    }

    package private(set) var tabs: [Tab] = []
    package private(set) var active: String?

    package init() {}

    package var paths: [String] { tabs.map(\.path) }

    package func contains(_ path: String) -> Bool {
        tabs.contains { $0.path == path }
    }

    /// Opens `path` and makes it active. Already open → activated (and kept,
    /// when this open is not a preview). A preview open replaces the current
    /// preview tab in place; anything else is inserted after the active tab.
    package mutating func open(_ path: String, preview: Bool) {
        if let index = index(of: path) {
            if !preview { tabs[index].isPreview = false }
            active = path
            return
        }
        let tab = Tab(path: path, isPreview: preview)
        if preview, let previewIndex = tabs.firstIndex(where: \.isPreview) {
            tabs[previewIndex] = tab
        } else {
            let insertAt = active.flatMap(index(of:)).map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: insertAt)
        }
        active = path
    }

    package mutating func activate(_ path: String) {
        if contains(path) { active = path }
    }

    /// A double click on the tab or the first edit in it.
    package mutating func pin(_ path: String) {
        if let index = index(of: path) { tabs[index].isPreview = false }
    }

    /// Closing the active tab activates its right neighbour, else its left.
    package mutating func close(_ path: String) {
        guard let index = index(of: path) else { return }
        tabs.remove(at: index)
        guard active == path else { return }
        active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].path
    }

    /// A file or folder was renamed or moved: every tab at `old` or under
    /// it (a folder) follows to `new`, keeping its place and preview state.
    package mutating func rename(_ old: String, to new: String) {
        func moved(_ path: String) -> String? {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
            return nil
        }
        tabs = tabs.map { tab in
            guard let path = moved(tab.path) else { return tab }
            return Tab(path: path, isPreview: tab.isPreview)
        }
        if let active, let path = moved(active) { self.active = path }
    }

    /// Closes `path` and every tab under it (a folder that went away).
    package mutating func closeTree(_ path: String) {
        for tab in tabs where tab.path == path || tab.path.hasPrefix(path + "/") { close(tab.path) }
    }

    /// A drag in the tab strip: `path` lands before `target` (nil = at the end).
    package mutating func move(_ path: String, before target: String?) {
        guard path != target, let from = index(of: path) else { return }
        let tab = tabs.remove(at: from)
        let to = target.flatMap(index(of:)) ?? tabs.count
        tabs.insert(tab, at: to)
    }

    /// Drops the tabs whose file is gone (`exists` false) — on restore.
    package mutating func prune(keeping exists: (String) -> Bool) {
        for tab in tabs where !exists(tab.path) { close(tab.path) }
    }

    /// What tells same-named tabs apart: the shortest run of parent folders
    /// that differs, nil for a name no other tab has ("main.go — cmd",
    /// "main.go — internal/sync").
    package var subtitles: [String: String] {
        var out: [String: String] = [:]
        let byName = Dictionary(grouping: paths) { ($0 as NSString).lastPathComponent }
        for (_, group) in byName where group.count > 1 {
            let parents = group.map { path in
                Array((path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init))
            }
            for (path, parts) in zip(group, parents) {
                out[path] = Self.shortestSuffix(parts, among: parents)
            }
        }
        return out
    }

    private static func shortestSuffix(_ parts: [String], among all: [[String]]) -> String {
        guard !parts.isEmpty else { return "./" }
        for length in 1...parts.count {
            let suffix = parts.suffix(length)
            let clashes = all.filter { $0 != parts && Array($0.suffix(length)) == Array(suffix) }
            if clashes.isEmpty { return suffix.joined(separator: "/") }
        }
        return parts.joined(separator: "/")
    }

    private func index(of path: String) -> Int? {
        tabs.firstIndex { $0.path == path }
    }

    package static func key(workbenchID: Int64) -> String { "workbench.files.tabs.\(workbenchID)" }
}
