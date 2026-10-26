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

    /// The phone reads the Desktop's tokens (WatchtowerDesign, one copy):
    /// its spacing steps and radii; a card takes the container radius; the
    /// flat row's insets stay the phone's own.
    func testTheMetricsAreTheDesktopsTokens() {
        XCTAssertEqual(
            [Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.cozy,
             Spacing.medium, Spacing.large, Spacing.page, Spacing.wide, Spacing.hero],
            [2, 4, 6, 8, 10, 12, 16, 20, 24, 40]
        )
        XCTAssertEqual(
            [Radius.mark, Radius.control, Radius.row, Radius.container, Radius.bubble, Radius.pill],
            [4, 6, 8, 10, 16, 18]
        )
        XCTAssertEqual(Card.radius, Radius.container)
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

    /// §2.4: medium and unknown get no mark; high is red, low blue; never
    /// orange.
    func testOnlyHighAndLowGetAPriorityMark() {
        XCTAssertEqual(PriorityMark.tone(.high), .red)
        XCTAssertEqual(PriorityMark.tone(.low), .blue)
        XCTAssertNil(PriorityMark.tone(.medium))
        XCTAssertNil(PriorityMark.tone(WorkbenchTargetPriority(rawValue: "newer")))
        XCTAssertEqual(PriorityMark.accessibilityLabel(.high), "High priority")
        XCTAssertEqual(PriorityMark.accessibilityLabel(.low), "Low priority")
        XCTAssertNil(PriorityMark.accessibilityLabel(.medium))
    }

    /// The Desktop's card (mockups 1–5): the soft `Fill.card` under a
    /// hairline, never an opaque system fill; a waiting card tints the same
    /// recipe in the waiting tone; the highlighted one is the board's
    /// selected card (`Fill.selected` under the accent selection stroke).
    func testTheCardPaints() {
        XCTAssertEqual(Card.paint(.plain), Card.Paint(fill: Fill.card, stroke: Stroke.hairlineColor, lineWidth: Stroke.hairline))
        XCTAssertEqual(Card.paint(.waiting), Card.Paint(
            fill: PhoneTone.waitingForYou.color.opacity(Fill.cardOpacity),
            stroke: PhoneTone.waitingForYou.color,
            lineWidth: Stroke.hairline
        ))
        XCTAssertEqual(Card.paint(.highlighted), Card.Paint(fill: Fill.selected, stroke: .accentColor, lineWidth: Stroke.selection))
        XCTAssertEqual(Card.padding, EdgeInsets(top: Spacing.cozy, leading: Spacing.medium, bottom: Spacing.cozy, trailing: Spacing.medium))
    }

    /// The Desktop's `Chip`: the tone at `ChipTint.fillOpacity` inside a
    /// `ChipTint.strokeOpacity` outline, the text in the tone; neutral is
    /// secondary on the same recipe.
    func testThePillPaints() {
        let tinted = Pill.paint(.tinted, tone: .red)
        XCTAssertEqual(tinted.fill, PhoneTone.red.color.opacity(ChipTint.fillOpacity))
        XCTAssertEqual(tinted.stroke, PhoneTone.red.color.opacity(ChipTint.strokeOpacity))
        XCTAssertEqual(tinted.text, PhoneTone.red.color)
        let neutral = Pill.paint(.neutral, tone: .red)
        XCTAssertEqual(neutral.fill, Color.secondary.opacity(ChipTint.fillOpacity))
        XCTAssertEqual(neutral.stroke, Color.secondary.opacity(ChipTint.strokeOpacity))
        XCTAssertEqual(neutral.text, .secondary)
    }

    /// `.kitRow`'s plate on the phone: clear at rest, `Fill.selected` when
    /// selected; rows are separated by space, not dividers.
    func testARowPlateIsClearUnlessSelected() {
        XCTAssertEqual(RowPlate.fill(isSelected: false), .clear)
        XCTAssertEqual(RowPlate.fill(isSelected: true), Fill.selected)
    }

    /// The Desktop's `SessionLiveDot`: a filled circle while the process
    /// runs, a ring otherwise.
    func testTheSessionDotIsTheDesktopsLiveDot() {
        XCTAssertEqual(SessionDot.symbol(isRing: false), "circle.fill")
        XCTAssertEqual(SessionDot.symbol(isRing: true), "circle")
    }

    /// The caps section header (Home's zone titles) reads its count too.
    func testTheSectionHeaderSpeaksItsCount() {
        XCTAssertEqual(SectionHeader.spokenLabel("Waiting for you", count: 3), "Waiting for you, 3")
        XCTAssertEqual(SectionHeader.spokenLabel("Working", count: nil), "Working")
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

    /// Final review I1: a shortened line says so with "…", and VoiceOver
    /// always hears every item.
    func testAShortenedMetaLineSaysSoAndSpeaksEveryItem() {
        let items = [
            MetaItem(text: "Working", tone: .green, role: .info),
            MetaItem(text: "#415 · 1/2", tone: .secondary, role: .info),
            MetaItem(text: "PR #175 open", tone: .secondary, role: .info)
        ]
        XCTAssertEqual(MetaLine.spokenLabel(items), "Working, #415 · 1/2, PR #175 open")
        XCTAssertFalse(MetaLine.isShortened(shown: 3, of: 3))
        XCTAssertTrue(MetaLine.isShortened(shown: 2, of: 3))
    }
}
