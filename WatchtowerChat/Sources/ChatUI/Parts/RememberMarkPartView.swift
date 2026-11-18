import SwiftUI
import WatchtowerDesign

/// The engine kept a `remember:` line for all chats (the `remember_mark` part).
struct RememberMarkPartView: View {
    static func line(_ rule: String) -> String { "Remembering for all chats: \(rule)" }

    let payload: ChatRememberPayload

    var body: some View {
        Label(Self.line(payload.rule), systemImage: "brain")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.rememberMark")
    }
}
