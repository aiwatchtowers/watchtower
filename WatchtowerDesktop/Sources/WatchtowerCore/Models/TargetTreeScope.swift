import Foundation

/// Decides whether a chat-proposed action may address another target: the
/// target-chat assistant can act on the current task's whole vertical line —
/// itself, any descendant (its sub-task tree), or any ancestor (its parent
/// chain) — but never a sibling branch or an unrelated task.
package enum TargetTreeScope {
    /// `parents` maps target id → parent_id (nil for roots). An id absent from
    /// the map is unknown and therefore out of scope.
    package static func isInScope(addressed: Int, current: Int, parents: [Int: Int?]) -> Bool {
        guard parents.keys.contains(addressed) else { return false }
        if addressed == current { return true }
        return chainUp(from: addressed, contains: current, parents: parents)
            || chainUp(from: current, contains: addressed, parents: parents)
    }

    /// Walks the parent chain starting at `start` (exclusive) looking for
    /// `wanted`. Guards against parent_id cycles in corrupt data.
    private static func chainUp(from start: Int, contains wanted: Int, parents: [Int: Int?]) -> Bool {
        var visited: Set<Int> = [start]
        var cursor = start
        while let entry = parents[cursor], let parent = entry {
            if parent == wanted { return true }
            guard visited.insert(parent).inserted else { return false }
            cursor = parent
        }
        return false
    }
}
