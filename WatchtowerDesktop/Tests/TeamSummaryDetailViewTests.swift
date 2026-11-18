import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class TeamSummaryDetailViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeSummary(
        summary: String = "",
        attention: String = "[]",
        tips: String = "[]"
    ) -> PeopleCardSummary {
        PeopleCardSummary(
            id: 1,
            periodFrom: 1714000000,
            periodTo: 1714600000,
            summary: summary,
            attention: attention,
            tips: tips,
            model: "claude-sonnet-4-6",
            inputTokens: 1500,
            outputTokens: 600,
            costUSD: 0.0123,
            promptVersion: 1,
            createdAt: "2026-04-23T10:00:00Z"
        )
    }

    // MARK: - Tests

    /// Заголовок «Team Summary» виден всегда.
    func testHeaderRendered() throws {
        let view = TeamSummaryDetailView(summary: makeSummary())
        XCTAssertNoThrow(try view.inspect().find(text: "Team Summary"))
    }

    /// Summary-секция показывается только когда summary непустой.
    func testSummarySectionShownWhenNonEmpty() throws {
        let view = TeamSummaryDetailView(summary: makeSummary(summary: "Team is healthy"))
        XCTAssertNoThrow(try view.inspect().find(text: "Team is healthy"))
    }

    /// Пустой summary → его текст в дереве отсутствует.
    func testSummarySectionHiddenWhenEmpty() throws {
        let view = TeamSummaryDetailView(summary: makeSummary(summary: ""))
        XCTAssertThrowsError(try view.inspect().find(text: "Summary"))
    }

    /// No "needs attention" list of people (#1769, A12): stored attention
    /// items are never shown, nor is any section for them.
    func testNoAttentionSection() throws {
        let attention = #"["Alice is overloaded","Slack noise increased"]"#
        let view = TeamSummaryDetailView(summary: makeSummary(attention: attention))
        XCTAssertThrowsError(try view.inspect().find(text: "Alice is overloaded"))
        XCTAssertThrowsError(try view.inspect().find(text: "Slack noise increased"))
        XCTAssertThrowsError(try view.inspect().find(text: "Needs Attention"))
    }

    /// Tips items парсятся и рендерятся (one "• " line each, under Tips).
    func testTipsItemsRendered() throws {
        let tips = #"["Schedule 1:1","Reduce meetings"]"#
        let view = TeamSummaryDetailView(summary: makeSummary(tips: tips))
        XCTAssertNoThrow(try view.inspect().find(text: PeopleCardCopy.tipsTitle))
        XCTAssertNoThrow(try view.inspect().find(text: "• Schedule 1:1"))
        XCTAssertNoThrow(try view.inspect().find(text: "• Reduce meetings"))
    }

    /// Metadata показывает модель и токены — one run line.
    func testMetadataShowsModelAndTokens() throws {
        let view = TeamSummaryDetailView(summary: makeSummary())
        // input + output = 2100
        XCTAssertNoThrow(try view.inspect().find(text: "claude-sonnet-4-6 · 2100 tokens · $0.0123"))
        XCTAssertEqual(
            PeopleCardCopy.runLine(model: "claude-sonnet-4-6", tokens: 2100, costUSD: 0.0123),
            "claude-sonnet-4-6 · 2100 tokens · $0.0123"
        )
    }

    /// onClose=nil → кнопка закрытия не строится.
    func testCloseButtonHiddenWithoutCallback() throws {
        let view = TeamSummaryDetailView(summary: makeSummary())
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertTrue(buttons.isEmpty,
                      "no buttons expected when onClose is nil")
    }

    /// onClose задан → кнопка есть и тап вызывает её.
    func testCloseButtonInvokesCallback() throws {
        var closed = 0
        let view = TeamSummaryDetailView(
            summary: makeSummary(),
            onClose: { closed += 1 }
        )

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(closed, 1)
    }
}
