import Foundation

/// The message tree of one conversation (spec §2.3): `parent_id` edges, the
/// visible thread being the path root → `active_leaf_message_id`. Pure — the
/// queries fetch `(id, parent_id)` once and ask this type everything.
package struct ChatTree: Sendable {
    package struct Node: Equatable, Sendable {
        package let id: Int64
        package let parentID: Int64?

        package init(id: Int64, parentID: Int64?) {
            self.id = id
            self.parentID = parentID
        }
    }

    private let known: Set<Int64>
    private let parentOf: [Int64: Int64]
    private let children: [Int64: [Int64]]
    private let roots: [Int64]

    package init(nodes: [Node]) {
        let sorted = nodes.sorted { $0.id < $1.id }
        known = Set(sorted.map(\.id))
        var parents: [Int64: Int64] = [:]
        var kids: [Int64: [Int64]] = [:]
        var rootIDs: [Int64] = []
        for node in sorted {
            if let parent = node.parentID {
                parents[node.id] = parent
                kids[parent, default: []].append(node.id)
            } else {
                rootIDs.append(node.id)
            }
        }
        parentOf = parents
        children = kids
        roots = rootIDs
    }

    /// Root → leaf ids; empty when the leaf is not in this conversation.
    package func path(toLeaf leaf: Int64) -> [Int64] {
        guard known.contains(leaf) else { return [] }
        var out: [Int64] = []
        var visited = Set<Int64>()
        var current: Int64? = leaf
        while let id = current, known.contains(id), visited.insert(id).inserted {
            out.append(id)
            current = parentOf[id]
        }
        return out.reversed()
    }

    /// Ids sharing `id`'s parent (roots share "no parent"), ascending.
    package func siblings(of id: Int64) -> [Int64] {
        guard let parent = parentOf[id] else { return roots }
        return children[parent] ?? [id]
    }

    /// The most recently created leaf in `id`'s subtree (`id` itself when it
    /// has no children) — where switching to a variant lands.
    package func newestLeaf(under id: Int64) -> Int64 {
        var leaves: [Int64] = []
        var stack = [id]
        var visited = Set<Int64>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            let kids = children[node] ?? []
            if kids.isEmpty { leaves.append(node) } else { stack.append(contentsOf: kids) }
        }
        return leaves.max() ?? id
    }
}
