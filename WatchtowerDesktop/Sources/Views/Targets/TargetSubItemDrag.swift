import Foundation

/// Payload + index math for reordering a target's checklist by drag & drop.
///
/// The checklist renders as a 2-column `LazyVGrid`, so SwiftUI's `List`-only
/// `onMove` is unavailable and each row carries its own `.draggable` /
/// `.dropDestination` pair. Both hand-rolled halves are error-prone, so they
/// live here (and under test) rather than inline in the view: the payload is
/// scoped to one target so foreign text dropped from another app reorders
/// nothing, and the drop index is translated into the
/// `move(fromOffsets:toOffset:)` offset, which sits one past the destination
/// when the item travels downwards.
enum TargetSubItemDrag {
    private static let prefix = "watchtower.target-subitem"

    static func payload(targetID: Int, index: Int) -> String {
        "\(prefix):\(targetID):\(index)"
    }

    /// The source index carried by `payload`, or nil when it is foreign text,
    /// another target's item, or an index the list no longer has (it can change
    /// under a drag in flight — `move(fromOffsets:)` traps out of range).
    static func sourceIndex(from payload: String, targetID: Int, itemCount: Int) -> Int? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == prefix,
              Int(parts[1]) == targetID,
              let index = Int(parts[2]),
              index >= 0, index < itemCount
        else { return nil }
        return index
    }

    /// `toOffset` for `Array.move(fromOffsets:toOffset:)` that lands the dragged
    /// item on `destinationIndex`; nil when the drop is a no-op.
    static func moveOffset(from sourceIndex: Int, to destinationIndex: Int) -> Int? {
        guard sourceIndex != destinationIndex else { return nil }
        return sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
    }
}
