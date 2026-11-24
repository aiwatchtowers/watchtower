import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// A run of answer text (the `text` part, after `ChatMessageParts` split its artifacts and question card out). The
/// platform part draws it: TextKit 2 on the Mac (`MarkdownTextRun`), SwiftUI runs on the phone (`MarkdownRuns`).
struct TextPartView: View {
    let payload: ChatTextPayload
    let context: ChatPartContext
    @Environment(\.chatHostText) private var hostText

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ChatAnswerText(text: payload.text, isFinal: context.isFinal, isOwner: context.message.role == "user",
                           highlighting: AgentTextHighlighting(context))
            if payload.textCut {
                Text(hostText.messageCut)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// How the agent's text is coloured and what its spans do (spec 2026-11-24-workchat-polish §2): only in a feed that
/// highlights (`ChatFeedContext.highlightsAgentText`) and only on the agent's own text.
struct AgentTextHighlighting {
    /// Whether a path candidate of this message is a file of the session's folders.
    let resolvesPath: (String) -> Bool
    /// A click on a span; nil keeps the spans inert (coloured only: no hand, clicks select as usual).
    let open: ((AgentTextHighlights.Span) -> Void)?

    /// Nil unless the feed highlights and the message is the agent's.
    init?(_ context: ChatPartContext) {
        guard context.highlightsAgentText, context.message.role == "assistant" else { return nil }
        let messageID = context.message.id
        let resolves = context.actions.resolvesPath
        resolvesPath = { path in resolves?(path, messageID) ?? false }
        open = context.actions.openHighlight.map { open in { span in open(span, messageID) } }
    }
}
