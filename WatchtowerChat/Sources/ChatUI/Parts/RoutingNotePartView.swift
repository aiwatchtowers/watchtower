import SwiftUI
import WatchtowerDesign

/// Which provider answered when it is not the one the chat asked for (the `routing_note` part).
struct RoutingNotePartView: View {
    let payload: ChatRoutingPayload

    var body: some View {
        Text(Self.line(payload))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.routingNote")
    }

    /// "Current provider: codex · gpt-x" (the Go fallback's words).
    static func line(_ payload: ChatRoutingPayload) -> String {
        let provider = payload.actualProvider ?? payload.provider ?? ""
        let model = payload.actualModel ?? payload.model ?? ""
        let named = [provider, model].filter { !$0.isEmpty }.joined(separator: " · ")
        return named.isEmpty ? "Current provider: automatic" : "Current provider: \(named)"
    }
}
