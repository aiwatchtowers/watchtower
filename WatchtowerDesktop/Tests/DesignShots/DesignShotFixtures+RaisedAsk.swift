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
    /// Go's title: the question on one line, clipped to 120 runes, no ellipsis.
    private static let title = String(question.prefix(120)).trimmingCharacters(in: .whitespaces)

    static func drawerTop() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            part(summary: question + "\nAsked in the terminal while you were away.")
            Divider()
            part(summary: "The folder check reads one root today; worktrees live beside it. I recommend yes.\n\n"
                + "Asked in the terminal; no answer for 12 min.")
            Spacer(minLength: 0)
        }
        .padding(12))
    }

    private static func part(summary: String) -> some View {
        let ask = raised(summary: summary)
        return VStack(alignment: .leading, spacing: 8) {
            OwnerAskHeaderCard(ask: ask)
            ChatQuestionCardView(card: ChatQuestionCard(questions: ask.payload.questions), answerText: nil, onAnswer: nil)
        }
    }

    private static func raised(summary: String) -> OwnerAsk {
        let payload = #"{"questions":[{"id":"q1","question":"\#(question)","options":[{"label":"Yes"},{"label":"No"}]}]}"#
        do {
            return try OwnerAsk(row: Row([
                "id": 12, "project_id": 1, "level": "full", "origin": "chat", "kind": "question",
                "title": title, "summary": summary, "payload": payload, "status": "open"
            ]))
        } catch {
            preconditionFailure("raised ask fixture: \(error)")
        }
    }
}
