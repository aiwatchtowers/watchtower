import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// Session rows during a spec review author loop (board #1945, spec
/// 2026-11-18-session-spec-review-state §10): a live session in round 1,
/// a not-live one in round 3 (ring), next to Working, Ready for review and
/// Idle for contrast. Captions come from `SessionStatePresentation`.
@MainActor
enum SpecReviewStateShotFixtures {
    static func rows(width: CGFloat) -> AnyView {
        func session(_ id: Int64, _ title: String) -> TerminalSession {
            TerminalSession(id: id, projectID: 1, kind: .claude, title: title, titleSource: .user,
                            folderPath: "/tmp/acme", createdAt: "2026-11-18T09:00:00Z",
                            lastActiveAt: "2026-11-18T09:00:00Z")
        }
        let readyForReview = SessionSwitcherPresentation.State.live(
            .readyToCheck, openAsks: 1, oldestAskID: 12, openQuestionAsks: 0, openReviewAsks: 1
        )
        let states: [(Int64, String, SessionSwitcherPresentation.State, String?)] = [
            (1, "acme invoice export spec", .init(kind: .specReview, live: true, specReviewRound: 1), "#41 · 0/4"),
            (2, "acme login redirect plan", .init(kind: .specReview, live: false, specReviewRound: 3), nil),
            (3, "acme billing export", .live(.working), "#42 · 3/5"),
            (4, "acme onboarding copy", readyForReview, "#43 · 5/5"),
            (5, "acme release notes", .live(.stopped), nil)
        ]
        let actions = SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in })
        return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach(states, id: \.0) { id, title, state, report in
                let row = SessionSwitcherPresentation.Row(
                    session: session(id, title), state: state,
                    caption: SessionStatePresentation.caption(for: state), badge: nil, shortcut: nil
                )
                TerminalSessionRow(row: row, actions: actions, reportLine: report, opensIn: .terminal)
                    .panelTab(isSelected: id == 1)
            }
        }
        .frame(width: width)
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelBackground())
    }
}
