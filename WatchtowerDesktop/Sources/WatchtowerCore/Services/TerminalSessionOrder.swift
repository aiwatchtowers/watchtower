import Foundation

/// The panel's order of a session list (board target #143): stable while the
/// owner switches between sessions, changed only by a drag. The rows' own
/// order (most recently active first) stays the VM's recency order; this is
/// display only, persisted per project in UserDefaults like the layout.
package enum TerminalSessionOrder {
    /// `projectID` nil = the standalone terminals.
    package static func key(projectID: Int64?) -> String {
        "projects.sessionOrder.\(projectID.map(String.init) ?? "standalone")"
    }

    /// Sessions the owner never placed come first, newest first (a new
    /// session appears at the top once, then stays where it is); the dragged
    /// order follows. Saved ids no longer listed are skipped.
    package static func apply(_ sessions: [TerminalSession], saved: [Int64]) -> [TerminalSession] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        let placed = Set(saved)
        let unplaced = sessions.filter { !placed.contains($0.id) }.sorted { $0.id > $1.id }
        var seen = Set<Int64>()
        let ordered = saved.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        return unplaced + ordered
    }

    /// A drag in the displayed list (SwiftUI's `onMove` offsets); returns the
    /// order to save — every displayed id, so later sessions go on top.
    package static func move(_ displayed: [TerminalSession], from source: IndexSet, to destination: Int) -> [Int64] {
        var ids = displayed.map(\.id)
        let moving = source.sorted().filter { $0 < ids.count }.map { ids[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where index < ids.count { ids.remove(at: index) }
        let insertAt = min(max(destination - before, 0), ids.count)
        ids.insert(contentsOf: moving, at: insertAt)
        return ids
    }
}
