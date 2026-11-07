import GRDB
import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// An ask Watchtower raised from the agent's terminal question, in its two
/// stored shapes: an old one (question + reason line) and a new one
/// (the agent's context, a blank line, the reason line).
@MainActor
enum RaisedAskShotFixtures {
    private static let question = "Extend `ai query --read-folder` from the workbench folder to the registered "
        + "worktrees of this workbench's sessions (terminal_session_worktrees)?"

    static func drawerTop() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            part(summary: question + "\nAsked in the terminal while you were away.")
            Divider()
            part(summary: "The folder check reads one root today; worktrees live beside it.\n\n"
                + "Asked in the terminal; no answer for 12 min.")
            Spacer(minLength: 0)
        }
        .padding(12))
    }

    @ViewBuilder
    private static func part(summary: String) -> some View {
        if let ask = raised(summary: summary) {
            VStack(alignment: .leading, spacing: 8) {
                OwnerAskHeaderCard(ask: ask)
                ChatQuestionCardView(card: ChatQuestionCard(questions: ask.payload.questions), answerText: nil, onAnswer: nil)
            }
        } else {
            Text("Broken fixture").foregroundStyle(.red)
        }
    }

    private static func raised(summary: String) -> OwnerAsk? {
        let payload = #"{"questions":[{"id":"q1","question":"\#(question)","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        return try? OwnerAsk(row: Row([
            "id": 12, "project_id": 1, "level": "full", "origin": "chat", "kind": "question",
            "title": question, "summary": summary, "payload": payload, "status": "open"
        ]))
    }
}
