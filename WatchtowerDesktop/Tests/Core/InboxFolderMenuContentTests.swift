import XCTest
@testable import WatchtowerCore

/// The Inbox rail's "Folders" heading (inbox redesign, phase 1): drawn only
/// above owner folders the rail shows. Sample data only.
final class InboxFolderMenuContentTests: XCTestCase {
    private let seed = [
        InboxFolderRow(id: 1, kind: .root, title: "Inbox", icon: "", depth: 0, count: 0),
        InboxFolderRow(id: 2, kind: .approvals, title: "Needs approval", icon: "", depth: 1, count: 0)
    ]

    func testFoldersHeadingOnlyWithOwnerFolders() {
        XCTAssertFalse(InboxFolderMenuContent(rows: seed).showsFoldersHeading, "the seed tree has no owner folder")

        let release = InboxFolderRow(id: 3, kind: .owner, title: "Release", icon: "flag", depth: 1, count: 2)
        XCTAssertTrue(InboxFolderMenuContent(rows: seed + [release]).showsFoldersHeading)

        var hidden = release
        hidden.hidden = true
        XCTAssertFalse(InboxFolderMenuContent(rows: seed + [hidden]).showsFoldersHeading,
                       "a hidden folder is not drawn while Show Hidden Folders is off")
        XCTAssertTrue(InboxFolderMenuContent(rows: seed + [hidden], showsHidden: true).showsFoldersHeading)
    }
}
