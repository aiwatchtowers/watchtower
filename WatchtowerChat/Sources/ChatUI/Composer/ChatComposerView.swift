import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The composer: the state line when the chat cannot be reached, the quotes and attachments of the draft, the field
/// (the platform part: the Mac's NSTextView, the phone's text field), the `@` picker, and Send or Stop.
public struct ChatComposerView: View {
    @Bindable var model: ChatComposerModel
    /// Opens the platform's file picker (the Mac's open panel, the phone's attachment menu); nil hides the button.
    var onAttach: (() -> Void)?
    @State private var cursor = 0
    @State private var hits: [ChatEntityHit] = []
    @Environment(\.chatUIStyle) private var style

    public init(model: ChatComposerModel, onAttach: (() -> Void)? = nil) {
        self.model = model
        self.onAttach = onAttach
    }

    private var conversation: ChatConversationModel { model.conversation }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let content = model.stateLine {
                ChatStateLineView(content: content) { conversation.performStateAction() }
            }
            if !hits.isEmpty {
                MentionPicker(hits: hits) { hit in
                    cursor = model.pick(hit, cursor: cursor)
                    hits = []
                }
            }
            chips
            HStack(alignment: .bottom, spacing: Spacing.regular) {
                if let onAttach {
                    Button(action: onAttach) { Image(systemName: "paperclip") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Attach")
                }
                ChatComposerTextInput(text: $model.draft, cursor: $cursor, placeholder: model.placeholder) {
                    Task { await model.send() }
                }
                sendOrStop
            }
            if let line = model.line {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.medium)
        .background {
            ChatComposerShortcuts(
                canSend: model.canSend,
                canStop: conversation.canStop,
                onSend: { Task { await model.send() } },
                onStop: { Task { await conversation.cancelTurn() } }
            )
        }
        .task(id: MentionQuery(text: model.draft, cursor: cursor)) {
            guard let query = MentionTokenizer.activeQuery(text: model.draft, cursor: cursor) else {
                hits = []
                return
            }
            hits = await model.search(entities: query)
        }
        .accessibilityIdentifier("chat.composer")
    }

    @ViewBuilder private var chips: some View {
        if !model.quotes.isEmpty || !model.attachments.isEmpty {
            HStack(spacing: Spacing.compact) {
                ForEach(model.quotes) { quote in
                    style.chip("“\(quote.quote.prefix(40))”")
                }
                ForEach(model.attachments) { attachment in
                    HStack(spacing: Spacing.tight) {
                        style.chip(attachment.name)
                        Button { Task { await model.removeAttachment(attachment.id) } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                }
            }
        }
    }

    @ViewBuilder private var sendOrStop: some View {
        if conversation.isTurnRunning {
            style.secondaryButton(ChatComposerModel.stopLabel) { Task { await conversation.cancelTurn() } }
                .disabled(!conversation.canStop)
                .accessibilityIdentifier("chat.composer.stop")
        } else {
            style.primaryButton(ChatComposerModel.sendLabel) { Task { await model.send() } }
                .disabled(!model.canSend)
                .accessibilityIdentifier("chat.composer.send")
        }
    }
}

private struct MentionQuery: Equatable {
    let text: String
    let cursor: Int
}
