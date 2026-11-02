import Foundation

/// Payload + move math for dragging a session row onto another to reorder a
/// session list (the workbench sessions panel's main list, the standalone
/// Terminals list).
///
/// The rows open on a click through a tap gesture, and on macOS a gesture on
/// a `List` row keeps SwiftUI's `onMove` from ever starting a drag, so each
/// row carries its own `.draggable` / `.dropDestination` pair. The payload is
/// scoped to one list (the workbench id, or none for the standalone list) and
/// names the session by id, so text dropped from another app or a row of
/// another list reorders nothing, and a reload during the drag cannot move
/// the wrong row.
package enum SessionRowDrag {
    private static let prefix = "watchtower.session-row"

    package static func payload(listID: Int64?, sessionID: Int64) -> String {
        "\(prefix):\(listID.map(String.init) ?? "standalone"):\(sessionID)"
    }

    /// The dragged session's id, or nil for foreign text or another list's row.
    package static func sessionID(from payload: String, listID: Int64?) -> Int64? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == prefix,
              parts[1] == listID.map(String.init) ?? "standalone",
              let id = Int64(parts[2])
        else { return nil }
        return id
    }

    /// The `onMove`-style offsets that put `dragged` in `target`'s slot of
    /// `displayed` (below it when it travels down, above it when it travels
    /// up); nil when either is not listed or the drop is on itself.
    package static func move(
        _ dragged: Int64, onto target: Int64, in displayed: [Int64]
    ) -> (source: IndexSet, destination: Int)? {
        guard let from = displayed.firstIndex(of: dragged),
              let to = displayed.firstIndex(of: target),
              from != to
        else { return nil }
        return (IndexSet(integer: from), from < to ? to + 1 : to)
    }
}
