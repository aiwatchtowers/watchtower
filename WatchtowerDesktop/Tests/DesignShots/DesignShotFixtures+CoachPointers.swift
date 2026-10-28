import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The coach's three entry points outside the Analytics pane (#1120): the
/// Home row (short, and a change over 4 lines), and the pointer under an
/// instruction field in Settings and in Agent Settings (analytics on / off).
@MainActor
enum CoachPointerShotFixtures {
    static func homeRow() -> AnyView {
        let short = HomeCoachProposal(
            proposal: CoachProposalFixture.make(
                id: 1, title: "Specs have no Non-goals section",
                after: "Every spec has a Non-goals section: what the feature deliberately does not do."),
            targetWorkbench: 1)
        let long = HomeCoachProposal(
            proposal: CoachProposalFixture.make(
                id: 2, title: "Agents skip the lint run", destination: "procedure", workbench: 1,
                before: "Keep diffs small.",
                after: (1...7).map { "Rule \($0): run make lint-diff before handing a task back." }.joined(separator: "\n")),
            targetWorkbench: 1)
        return AnyView(VStack(alignment: .leading, spacing: 24) {
            WorkbenchZoneView(blocks: [], coach: short, failed: false, onLink: { _ in },
                              onDecideCoach: { _, _ in nil }, onOpenCoach: { _ in })
            WorkbenchZoneView(blocks: [], coach: long, failed: false, onLink: { _ in },
                              onDecideCoach: { _, _ in nil }, onOpenCoach: { _ in })
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    /// `analyticsOn`/`settings` pick the line and the host's text.
    static func pointer(settings: Bool) -> AnyView {
        func block(_ title: String, _ text: String) -> some View {
            InstructionFieldBlock(
                title: title, caption: "Added after your global text in every new session.", stored: "Reply in the language of the owner.",
                limit: 1000, error: nil, busy: false, draft: .constant(nil), onSave: { _ in },
                coachPointer: CoachPointer(text: text) {})
        }
        return AnyView(VStack(alignment: .leading, spacing: 16) {
            if settings {
                block("For chats and agents", InstructionsSettingsSection.coachPointerText)
            } else {
                block("Session instructions", AgentSettingsScreen.coachPointerText(analyticsOn: true))
                block("Target procedure", AgentSettingsScreen.coachPointerText(analyticsOn: false))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }
}
