/// The Inbox root (mobile Inbox spec §7, mockup §1): the folder menu and
/// the tab badge.
public struct InboxRootModel: Equatable, Sendable {
    /// The root folder, whose cards are the root's own entries.
    public let rootFolderID: Int64?
    /// The folders under the root, by position, three levels deep. A hidden
    /// folder (and so everything under it) is left out. On the phone Needs
    /// approval is listed only while it holds something.
    public let rows: [InboxFolderRow]
    /// The phone's tab badge: the sum of the shown folders' `waiting` (open
    /// approvals and open rows that wait on the owner; ask #1349).
    public let badge: Int
    /// The Mac's sidebar badge: the sum of the shown folders' `count`
    /// (`InboxFolderCounts.badge`).
    public let countBadge: Int

    public init(feed: Feed, platform: Platform) {
        let tree = InboxFolderTree(feed.folders)
        rootFolderID = tree.root?.id
        let shown = feed.folders.filter { !$0.hidden }
        badge = shown.reduce(0) { $0 + $1.waiting }
        countBadge = shown.reduce(0) { $0 + $1.count }
        rows = tree.children(of: tree.root?.id)
            .filter { platform == .mac || $0.kind != .approvals || tree.total($0.id).cards > 0 }
            .map { tree.row($0, depth: 0) }
    }
}

/// One folder of the menu. A level-3 folder's count and waiting take in
/// every folder below it (Review Focus 5: deeper folders roll up rather
/// than vanish).
public struct InboxFolderRow: Equatable, Sendable {
    public let folder: Folder
    /// 0...2 below the root.
    public let depth: Int
    public let count: Int
    public let waiting: Int
    public let children: [Self]
}

/// The feed's folders as a tree: each shown folder's place, and which drawn
/// folder (three levels at most) its cards and counts belong to.
struct InboxFolderTree {
    /// Levels drawn below the root.
    static let levels = 3

    let root: Folder?
    private let byID: [Int64: Folder]
    private let childIDs: [Int64?: [Folder]]

    init(_ folders: [Folder]) {
        let shown = folders.filter { !$0.hidden }
        root = shown.first { $0.kind == .root }
        byID = Dictionary(shown.map { ($0.id, $0) }) { first, _ in first }
        var children: [Int64?: [Folder]] = [:]
        for folder in shown where folder.kind != .root {
            // A folder with no parent hangs off the root.
            children[folder.parentID ?? root?.id, default: []].append(folder)
        }
        childIDs = children.mapValues { $0.sorted { ($0.position, $0.id) < ($1.position, $1.id) } }
    }

    func children(of id: Int64?) -> [Folder] {
        childIDs[id] ?? []
    }

    func row(_ folder: Folder, depth: Int) -> InboxFolderRow {
        let last = depth == Self.levels - 1
        let own = last ? total(folder.id) : (cards: folder.count, waiting: folder.waiting)
        return InboxFolderRow(
            folder: folder, depth: depth, count: own.cards, waiting: own.waiting,
            children: last ? [] : children(of: folder.id).map { row($0, depth: depth + 1) }
        )
    }

    /// A folder's counts with every shown folder below it.
    func total(_ id: Int64) -> (cards: Int, waiting: Int) {
        var sum = (cards: byID[id]?.count ?? 0, waiting: byID[id]?.waiting ?? 0)
        var stack = children(of: id)
        var seen: Set<Int64> = [id]
        while let next = stack.popLast() {
            guard seen.insert(next.id).inserted else { continue }
            sum.cards += next.count
            sum.waiting += next.waiting
            stack.append(contentsOf: children(of: next.id))
        }
        return sum
    }

    /// The drawn folder a folder's cards are listed in: itself, or its
    /// level-3 ancestor when it sits deeper. nil for a folder not shown.
    func drawnID(of id: Int64) -> Int64? {
        guard let folder = byID[id] else { return nil }
        var chain = [folder.id]
        var current = folder
        while current.kind != .root, let parent = current.parentID, let up = byID[parent], !chain.contains(up.id) {
            chain.append(up.id)
            current = up
        }
        // chain runs from the folder up to the root (or the top shown folder).
        let levelsBelowRoot = current.kind == .root ? chain.count - 1 : chain.count
        guard levelsBelowRoot > Self.levels else { return folder.id }
        return chain[levelsBelowRoot - Self.levels]
    }
}
