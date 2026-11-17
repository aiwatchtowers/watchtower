import XCTest
import WatchtowerInterface
@testable import WatchtowerCore

/// The Inbox menu's folders are Go's (`Feed.folders`), not the local read's:
/// a folder the feed lists shows, one only the local tree has does not, and
/// a folder is drawn hidden only where its own flag hid it.
final class InboxTowerEntriesTreeTests: XCTestCase {
    private func folder(_ id: Int64, _ kind: FolderKind, parent: Int64?, slug: String, hidden: Bool = false) -> Folder {
        Folder(id: id, kind: kind, slug: slug, title: slug.capitalized, icon: "", parentID: parent, position: Int(id),
               hidden: hidden, count: 0, waiting: 0)
    }

    func testTheMenuFoldersAreTheFeeds() {
        let local = InboxFolderTree(revision: 7, folders: [
            InboxFolder(id: 1, kind: .root, parentID: nil, slug: "inbox", title: "Inbox"),
            InboxFolder(id: 9, kind: .owner, parentID: 1, slug: "gone", title: "Gone")
        ], routes: [3: 9])
        let feed = Feed(v: 1, builtAt: "", folders: [
            folder(1, .root, parent: nil, slug: "inbox"),
            folder(2, .approvals, parent: 1, slug: "needs-approval"),
            folder(3, .owner, parent: 1, slug: "release", hidden: true),
            folder(4, .owner, parent: 3, slug: "blockers", hidden: true)
        ], cards: [])

        let tree = InboxTowerEntries.tree(local, feed: feed)

        XCTAssertEqual(tree.folders.map(\.id), [1, 2, 3, 4], "Go's folders in Go's order; the local-only one is gone")
        XCTAssertEqual(tree.folders.map(\.hidden), [false, false, true, false],
                       "hidden where its own flag hid it; the child is hidden through its parent")
        XCTAssertEqual(tree.approvals?.id, 2)
        XCTAssertEqual(tree.revision, 7, "the CLI's revision stays the local read's")
        XCTAssertEqual(tree.routes, [3: 9])
        XCTAssertEqual(InboxTowerEntries.tree(local, feed: Feed(v: 1, builtAt: "", folders: [], cards: [])), local,
                       "no feed folders yet: the local tree")
    }
}
