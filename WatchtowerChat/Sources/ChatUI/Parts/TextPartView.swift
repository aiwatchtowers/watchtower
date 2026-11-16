import ChatWire
import SwiftUI
import WatchtowerDesign

/// A run of answer text (the `text` part, after `ChatMessageParts` split its artifacts and question card out). The
/// platform part draws it: TextKit 2 on the Mac (`MarkdownTextRun`), SwiftUI runs on the phone (`MarkdownRuns`).
struct TextPartView: View {
    static let cutLine = "This message is cut here; the whole text is on your Mac."

    let payload: ChatTextPayload
    let context: ChatPartContext

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ChatAnswerText(text: payload.text, isFinal: context.isFinal, isOwner: context.message.role == "user")
            if payload.textCut {
                Text(Self.cutLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
