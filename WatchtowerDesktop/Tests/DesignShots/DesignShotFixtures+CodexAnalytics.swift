import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Codex sessions in the Analytics pane (U4, board #975): session rows with
/// their agent's tag and "no price", and the Context and Skills cards with
/// the "Not measured for Codex sessions." caption, on fixture data.
@MainActor
enum CodexAnalyticsShotFixtures {
    /// The overview with Claude Code and Codex sessions in one period.
    static func blocks() -> AnyView {
        do {
            return AnyView(AgentAnalyticsOverviewView(
                state: .overview(try overview(), staleError: nil), period: .constant(.week), actions: actions
            ).detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The Sessions table (folded under Time on the pane) on its own; a
    /// narrow shot shows the compact rows.
    static func sessions() -> AnyView {
        do {
            let sessions = try overview().sessions
            return AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
                Text("Sessions").font(.subheadline.weight(.semibold))
                AgentAnalyticsSessionsTable(sessions: sessions, actions: actions)
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static let actions = AgentAnalyticsActions(
        turnOn: {}, openSession: { _ in }, openTarget: { _ in }, openFile: { _ in },
        openAsks: {}, discuss: { _ in }, asksWaiting: false
    )

    /// The Statistics fixture with two Codex sessions added beside its
    /// Claude Code ones (`codexOnly` keeps the Codex ones alone).
    static func overview(codexOnly: Bool = false) throws -> AgentReportOverview {
        var json = try StatisticsShotFixtures.json()
        let claude = codexOnly ? [] : try XCTUnwrap(json["sessions"] as? [[String: Any]])
        json["sessions"] = claude + codexSessions
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static let codexSessions: [[String: Any]] = [
        session(uuid: "33333333-aaaa-bbbb-cccc-000000000003", model: "gpt-6-sol", branch: "feature/cache-keys",
                activeMS: 1_860_000, calls: 14),
        session(uuid: "44444444-aaaa-bbbb-cccc-000000000004", model: "gpt-6-luna", branch: "fix/login-redirect",
                activeMS: 540_000, calls: 5)
    ]

    private static func session(
        uuid: String, model: String, branch: String, activeMS: Int64, calls: Int
    ) -> [String: Any] {
        [
            "session_uuid": uuid, "agent": "codex", "cost_estimated_calls": calls,
            "started_at": "2026-10-02T09:00:00.000Z", "ended_at": "2026-10-02T09:40:00.000Z",
            "model": model, "branch": branch, "active_ms": activeMS, "cost_usd": 0,
            "avg_parallel": 0, "old_format": false, "prs": [String]()
        ]
    }
}
