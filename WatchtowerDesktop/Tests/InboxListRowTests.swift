import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Inbox list's row (spec "The list", mockup): the kind's tile and
/// tint, the unread dot, the count pill, one VoiceOver element, and a ⋯
/// that never changes the row's height.
@MainActor
final class InboxListRowTests: XCTestCase {
    private static let content = InboxRowContent(
        kind: .peopleWaiting, title: "Waiting for me",
        preview: "Colleague B in a DM: “Will you approve the budget?” · and 11 more today",
        meta: "People in Slack and Jira · 14 older, folded", time: "08:10",
        pill: InboxRowPill(count: 12, tone: .needsYou), isUnread: true)

    func testUnreadDotAndPill() throws {
        let unread = InboxListRow(content: Self.content, isSelected: false)
        XCTAssertNoThrow(try unread.inspect().find(viewWithAccessibilityIdentifier: "inbox.row.unread"))
        XCTAssertEqual(try unread.inspect().find(InboxRowPillView.self).actualView().pill.count, 12)
        XCTAssertNoThrow(try unread.inspect().find(text: "12"))
        XCTAssertNoThrow(try unread.inspect().find(text: "08:10"))

        let read = InboxListRow(
            content: InboxRowContent(kind: .threads, title: "Track my threads", preview: "ACME-12 got a reply"),
            isSelected: false)
        XCTAssertThrowsError(try read.inspect().find(viewWithAccessibilityIdentifier: "inbox.row.unread"))
        XCTAssertThrowsError(try read.inspect().find(InboxRowPillView.self))

        XCTAssertEqual(InboxListRow.accessibilityLabel(Self.content),
                       "Waiting for me, \(Self.content.preview), 12")
        XCTAssertEqual(try unread.inspect().find(ViewType.HStack.self).accessibilityValue().string(), "Unread")

        XCTAssertEqual(InboxRowPillView.fill(.needsYou), Tone.warning)
        XCTAssertEqual(InboxRowPillView.fill(.news), Color.accentColor)
        XCTAssertEqual(InboxRowPillView.fill(.batch), Fill.card)
    }

    func testTileTintsPerKind() {
        let expected: [(InboxRowKind, Color, String)] = [
            (.brief, Tone.amber, "sun.max"),
            (.peopleWaiting, Tone.warning, "person.2"),
            (.mailWaiting, Tone.success, "envelope"),
            (.slackToday, Color.accentColor, "number"),
            (.threads, Color.accentColor, "bubble.left.and.bubble.right"),
            (.ideas, Tone.status("purple"), "lightbulb"),
            (.approval, Tone.warning, "checkmark.seal"),
            (.artifact, Color.accentColor, "folder")
        ]
        for (kind, tint, symbol) in expected {
            XCTAssertEqual(InboxTile.tint(kind), tint, "\(kind)")
            XCTAssertEqual(InboxTile.symbol(kind), symbol, "\(kind)")
        }
    }

    func testHoverMenuKeepsRowHeight() {
        let width: CGFloat = 340
        let plain = InboxListRow(content: Self.content, isSelected: false)
        let withMenu = InboxListRow(content: Self.content, isSelected: false,
                                    menu: InboxFolderEntry.legacyIdeas.menuEntries)
        let shown = InboxListRow(content: Self.content, isSelected: true,
                                 menu: InboxFolderEntry.legacyIdeas.menuEntries)
        let height = ViewRenderProbe.fittingHeight(plain, width: width)
        XCTAssertGreaterThan(height, 0)
        XCTAssertEqual(ViewRenderProbe.fittingHeight(withMenu, width: width), height)
        XCTAssertEqual(ViewRenderProbe.fittingHeight(shown, width: width), height, "the ⋯ on screen")

        let bare = InboxRowContent(kind: .ideas, title: "Idea finder")
        XCTAssertEqual(
            ViewRenderProbe.fittingHeight(InboxListRow(content: bare, isSelected: true,
                                                       menu: InboxFolderEntry.legacyIdeas.menuEntries), width: width),
            ViewRenderProbe.fittingHeight(InboxListRow(content: bare, isSelected: true), width: width),
            "a one-line row with no time keeps its height under the ⋯ too")
    }
}
