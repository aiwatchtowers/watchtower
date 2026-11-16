import Foundation
import WatchtowerInterface
import XCTest

/// Feeds for the screen-model tests, built from the Go golden
/// `internal/tower/api/testdata/Feed.json` and small edits of its records.
enum InboxFixtures {
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Support
        .deletingLastPathComponent()  // …/WatchtowerInterfaceTests
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerInterface
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/tower/api/testdata/Feed.json")

    static func golden() throws -> Feed {
        try JSONDecoder().decode(Feed.self, from: Data(contentsOf: testdata))
    }

    /// The golden's Waiting for me artifact (`o1`).
    static func artifact(
        _ id: String,
        folder: Int64 = 1,
        stamp: String = "2026-11-16T11:50:00Z",
        pinned: Bool = false,
        unread: Bool = false,
        actions: [CardAction] = [],
        refs: [RefFacts] = []
    ) throws -> Card {
        var card = try XCTUnwrap(golden().cards.first { $0.id == "o1" })
        card.id = id
        card.folderID = folder
        card.title = "Card \(id)"
        card.stamp = stamp
        card.pinned = pinned
        card.unread = unread
        card.actions = actions
        card.refFacts = refs
        return card
    }

    /// The golden's native approval (`a5`), with `edit`.
    static func approval(_ id: String = "a5", folder: Int64 = 2, edit: (inout Approval) -> Void = { _ in }) throws -> Card {
        var card = try XCTUnwrap(golden().cards.first { $0.id == "a5" })
        card.id = id
        card.folderID = folder
        var approval = try XCTUnwrap(card.approval)
        edit(&approval)
        card.approval = approval
        return card
    }

    static func folder(
        _ id: Int64,
        kind: FolderKind = .owner,
        parent: Int64? = 1,
        position: Int = 0,
        count: Int = 0,
        waiting: Int = 0,
        hidden: Bool = false
    ) -> Folder {
        Folder(
            id: id, kind: kind, slug: "f\(id)", title: "Folder \(id)", icon: "", parentID: parent,
            position: position, hidden: hidden, count: count, waiting: waiting
        )
    }

    static let root = folder(1, kind: .root, parent: nil)

    static func feed(folders: [Folder], cards: [Card] = [], more: [FolderMore]? = nil) -> Feed {
        Feed(v: 1, builtAt: "2026-11-16T12:00:00Z", folders: folders, cards: cards, more: more)
    }

    static func action(
        _ index: Int,
        kind: String,
        label: String = "Button",
        state: ActionState = .enabled,
        detail: String = "",
        note: String = "",
        until: String = ""
    ) -> CardAction {
        CardAction(index: index, kind: kind, label: label, state: state, detail: detail, note: note, until: until)
    }

    static func ref(_ kind: RefKind, _ id: Int64, open: Bool = true, reply: Bool = false) -> RefFacts {
        RefFacts(kind: kind, id: id, open: open, waits: open, reply: reply, replyWaiting: false, link: "")
    }

    static func date(_ stamp: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(stamp)
    }

    static func zone(_ id: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: id))
    }
}
