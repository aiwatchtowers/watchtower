import SwiftUI
import WatchtowerDesign

/// The engine saved a `решили:`/`факт:` line as a decision or a fact (the `knowledge_mark` part).
struct KnowledgeMarkPartView: View {
    static func line(kind: String) -> String { kind == "note" ? "Saved as a fact" : "Saved as a decision" }

    let payload: ChatKnowledgePayload

    var body: some View {
        Label(Self.line(kind: payload.kind), systemImage: "lightbulb")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.knowledgeMark")
    }
}
