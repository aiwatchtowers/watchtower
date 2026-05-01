import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class GuideDetailViewTests: XCTestCase {

    // MARK: - Helpers

    /// CommunicationGuide is Decodable-only; build via JSON.
    private func makeGuide(
        summary: String = "",
        preferences: String = "",
        availability: String = "",
        decision: String = "",
        tactics: String = "[]",
        approaches: String = "[]",
        recommendations: String = "[]",
        activeHours: String = "{}"
    ) -> CommunicationGuide {
        let json = """
        {
          "id": 1,
          "user_id": "U1",
          "period_from": 1714000000,
          "period_to": 1714600000,
          "message_count": 87,
          "channels_active": 5,
          "threads_initiated": 3,
          "threads_replied": 12,
          "avg_message_length": 42.5,
          "active_hours_json": \(quoted(activeHours)),
          "volume_change_pct": 12.5,
          "summary": \(quoted(summary)),
          "communication_preferences": \(quoted(preferences)),
          "availability_patterns": \(quoted(availability)),
          "decision_process": \(quoted(decision)),
          "situational_tactics": \(quoted(tactics)),
          "effective_approaches": \(quoted(approaches)),
          "recommendations": \(quoted(recommendations)),
          "relationship_context": "",
          "model": "claude-haiku-4-5",
          "input_tokens": 1000,
          "output_tokens": 400,
          "cost_usd": 0.0042,
          "created_at": "2026-04-23T10:00:00Z"
        }
        """
        return try! JSONDecoder().decode(CommunicationGuide.self, from: Data(json.utf8))
    }

    /// JSON-quoted string with backslash + double-quote escaping.
    private func quoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Tests

    /// Header показывает "@<userName>", "Communication Guide" и stats.
    func testHeaderAndStatsRendered() throws {
        let view = GuideDetailView(guide: makeGuide(), userName: "alice")
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "@alice"))
        XCTAssertNoThrow(try inspected.find(text: "Communication Guide"))
        // statsGrid values
        XCTAssertNoThrow(try inspected.find(text: "87"))
        XCTAssertNoThrow(try inspected.find(text: "5"))
        // volumeChangePct = 12.5 → форматируется как "+12%"
        XCTAssertNoThrow(try inspected.find(text: "+12%"))
    }

    /// Summary section показывается только если summary непустой.
    func testSummarySectionConditional() throws {
        let withSummary = GuideDetailView(
            guide: makeGuide(summary: "Direct, prefers async."),
            userName: "alice"
        )
        XCTAssertNoThrow(try withSummary.inspect().find(text: "How to Work With Them"))
        XCTAssertNoThrow(try withSummary.inspect().find(text: "Direct, prefers async."))

        let empty = GuideDetailView(guide: makeGuide(summary: ""), userName: "alice")
        XCTAssertThrowsError(try empty.inspect().find(text: "How to Work With Them"))
    }

    /// Preferences/Availability/Decision sections — каждая независимо conditional.
    func testStringSectionsConditional() throws {
        let view = GuideDetailView(
            guide: makeGuide(
                preferences: "Async over sync",
                availability: "9-5 UTC",
                decision: "Consults team"
            ),
            userName: "alice"
        )
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Communication Preferences"))
        XCTAssertNoThrow(try inspected.find(text: "Async over sync"))
        XCTAssertNoThrow(try inspected.find(text: "Availability Patterns"))
        XCTAssertNoThrow(try inspected.find(text: "9-5 UTC"))
        XCTAssertNoThrow(try inspected.find(text: "Decision Process"))
        XCTAssertNoThrow(try inspected.find(text: "Consults team"))
    }

    /// Situational tactics — JSON массив парсится в список Label'ов.
    func testTacticsListParsed() throws {
        let view = GuideDetailView(
            guide: makeGuide(tactics: #"["Ping in DM","Avoid morning standups"]"#),
            userName: "alice"
        )
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Situational Tactics"))
        XCTAssertNoThrow(try inspected.find(text: "Ping in DM"))
        XCTAssertNoThrow(try inspected.find(text: "Avoid morning standups"))
    }

    /// Recommendations и Approaches — то же самое.
    func testApproachesAndRecommendationsParsed() throws {
        let view = GuideDetailView(
            guide: makeGuide(
                approaches: #"["Direct questions","Written summaries"]"#,
                recommendations: #"["Schedule 1:1"]"#
            ),
            userName: "alice"
        )
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "What Works Well"))
        XCTAssertNoThrow(try inspected.find(text: "Direct questions"))
        XCTAssertNoThrow(try inspected.find(text: "Recommendations"))
        XCTAssertNoThrow(try inspected.find(text: "Schedule 1:1"))
    }

    /// Active hours chart — рендерится секция, когда JSON непустой.
    func testActiveHoursChartConditional() throws {
        let view = GuideDetailView(
            guide: makeGuide(activeHours: #"{"9":3,"10":5,"15":2}"#),
            userName: "alice"
        )
        XCTAssertNoThrow(try view.inspect().find(text: "Active Hours (UTC)"))
    }

    /// onClose=nil → нет кнопки закрытия.
    func testCloseButtonHiddenWithoutCallback() throws {
        let view = GuideDetailView(guide: makeGuide(), userName: "alice")
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertTrue(buttons.isEmpty)
    }

    /// onClose задан → кнопка есть и тап вызывает её.
    func testCloseButtonInvokesCallback() throws {
        var closed = 0
        let view = GuideDetailView(
            guide: makeGuide(),
            userName: "alice",
            onClose: { closed += 1 }
        )

        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(closed, 1)
    }
}
