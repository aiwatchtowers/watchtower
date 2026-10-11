import SwiftUI
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The phone's design layer (design pass spec §2): tones, metrics, the
/// target status table, the priority dot, card paints and the wrapping row.
final class DesignSystemTests: XCTestCase {
    /// §2.2: teal (in review) and gray (dismissed) are the system colours.
    func testTheNewTonesAreTheSystemTealAndGray() {
        XCTAssertEqual(PhoneTone.teal.color, .teal)
        XCTAssertEqual(PhoneTone.gray.color, .gray)
        XCTAssertNotEqual(PhoneTone.waitingForYou, .teal)
        XCTAssertNotEqual(PhoneTone.waitingForYou, .gray)
    }

    /// §2.9: the Mac's spacing steps plus 20 for page margins; one radius
    /// per role; the flat row's insets.
    func testTheMetricsNameTheMacsSteps() {
        XCTAssertEqual(
            [Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.medium, Spacing.large, Spacing.page],
            [2, 4, 6, 8, 12, 16, 20]
        )
        XCTAssertEqual([Radius.chip, Radius.row, Radius.card], [6, 8, 12])
        XCTAssertEqual(RowInsets.flat, EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        XCTAssertEqual(RowInsets.card, EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    /// §2.3: the Mac's model table (`Target.swift:280-300`) for every known
    /// status, an unknown one draws a secondary circle, none is orange.
    func testTargetStatusFollowsTheMacsModelTable() {
        let expected: [(WorkbenchTargetStatus, String, PhoneTone)] = [
            (.todo, "circle", .secondary),
            (.inProgress, "circle.dotted.circle", .blue),
            (.inReview, "eye.circle", .teal),
            (.blocked, "exclamationmark.circle", .red),
            (.done, "checkmark.circle.fill", .green),
            (.dismissed, "xmark.circle", .gray),
            (.snoozed, "moon.circle", .purple)
        ]
        XCTAssertEqual(expected.map(\.0), WorkbenchTargetStatus.knownValues, "the table covers every known status")
        for (status, glyph, tone) in expected + [(WorkbenchTargetStatus(rawValue: "newer"), "circle", .secondary)] {
            let style = TargetStatusStyle.of(status)
            XCTAssertEqual(style.glyph, glyph, status.rawValue)
            XCTAssertEqual(style.tone, tone, status.rawValue)
            XCTAssertNotEqual(style.tone, .orange, status.rawValue)
            XCTAssertEqual(BoardRowModel.status(status).glyph, glyph, "the board row forwards")
        }
    }

    /// §2.4: medium and unknown draw no dot; high is red, low blue; never
    /// orange.
    func testOnlyHighAndLowGetAPriorityDot() {
        XCTAssertEqual(PriorityMark.tone(.high), .red)
        XCTAssertEqual(PriorityMark.tone(.low), .blue)
        XCTAssertNil(PriorityMark.tone(.medium))
        XCTAssertNil(PriorityMark.tone(WorkbenchTargetPriority(rawValue: "newer")))
        XCTAssertEqual(PriorityMark.accessibilityLabel(.high), "High priority")
        XCTAssertEqual(PriorityMark.accessibilityLabel(.low), "Low priority")
        XCTAssertNil(PriorityMark.accessibilityLabel(.medium))
    }

    /// §2.5: one radius, three paints; the dark waiting fill is weaker on
    /// purpose (orange at 0.10 on black reads brown).
    func testTheCardPaints() {
        let waitingLight = Card.paint(.waiting, scheme: .light)
        let waitingDark = Card.paint(.waiting, scheme: .dark)
        XCTAssertEqual(waitingLight.fill, PhoneTone.waitingForYou.color.opacity(0.10))
        XCTAssertEqual(waitingDark.fill, PhoneTone.waitingForYou.color.opacity(0.06))
        XCTAssertEqual(waitingLight.stroke, PhoneTone.waitingForYou.color.opacity(0.45))
        XCTAssertEqual(waitingDark.stroke, PhoneTone.waitingForYou.color.opacity(0.30))
        XCTAssertEqual(waitingLight.lineWidth, 1)
        XCTAssertEqual(Card.paint(.plain, scheme: .dark).lineWidth, 0.5)
        XCTAssertEqual(Card.paint(.highlighted, scheme: .dark).fill, Color.accentColor.opacity(0.14))
        XCTAssertEqual(Card.paint(.highlighted, scheme: .light).lineWidth, 1.5)
        XCTAssertEqual(Card.padding, EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    /// §2.11 and review focus 4: items wrap 6 pt apart with 4 pt between
    /// lines; an item wider than the row gets a line of its own at the
    /// row's width (so it truncates); no items take no space.
    func testFlowRowWrapsClampsAndCollapses() {
        let item = CGSize(width: 100, height: 20)
        let wrapped = FlowRow.arrange(sizes: [item, item, item], maxWidth: 250, spacing: 6, lineSpacing: 4)
        XCTAssertEqual(wrapped.frames.map(\.origin), [.zero, CGPoint(x: 106, y: 0), CGPoint(x: 0, y: 24)])
        XCTAssertEqual(wrapped.size, CGSize(width: 206, height: 44))

        let wide = FlowRow.arrange(sizes: [item, CGSize(width: 900, height: 20)], maxWidth: 250, spacing: 6, lineSpacing: 4)
        XCTAssertEqual(wide.frames[1], CGRect(x: 0, y: 24, width: 250, height: 20))
        XCTAssertEqual(wide.size.width, 250)

        XCTAssertEqual(FlowRow.arrange(sizes: [], maxWidth: 250, spacing: 6, lineSpacing: 4).size, .zero)
    }

    /// The board's details are meta items: one type for every meta line.
    func testABoardDetailIsAMetaItem() {
        let detail: BoardDetail = MetaItem(text: "1 ask", tone: .waitingForYou, role: .ask)
        XCTAssertEqual(detail.text, "1 ask")
    }

    /// Phase 2 gate (shot 05): a meta line shows whole items, the longest
    /// prefix that fits, so a squeezed line never reads "· I ·"; the
    /// one-item line is the last resort and truncates.
    func testAMetaLineTriesItsPrefixesLongestFirst() {
        XCTAssertEqual(MetaLine.prefixLengths(3), [3, 2, 1])
        XCTAssertEqual(MetaLine.prefixLengths(1), [1])
        XCTAssertEqual(MetaLine.prefixLengths(0), [])
    }
}
