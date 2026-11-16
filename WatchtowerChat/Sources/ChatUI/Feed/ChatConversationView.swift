import ChatWire
import SwiftUI
import WatchtowerDesign

/// The conversation screen's body (feed + composer), shared by the Mac's chat window, its ⌘/ panel and the phone. The
/// navigation shell around it (split view, inspector, tab bar) stays in each app.
public struct ChatConversationView: View {
    let conversation: ChatConversationModel
    let composer: ChatComposerModel
    let partActions: ChatPartActions
    var onAttach: (() -> Void)?

    public init(
        conversation: ChatConversationModel, composer: ChatComposerModel, partActions: ChatPartActions,
        onAttach: (() -> Void)? = nil
    ) {
        self.conversation = conversation
        self.composer = composer
        self.partActions = partActions
        self.onAttach = onAttach
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatFeedView(messages: conversation.messages, context: feedContext)
            ChatComposerView(model: composer, onAttach: onAttach)
        }
        .onAppear { conversation.start() }
        .onDisappear { conversation.stop() }
        .task(id: conversation.messages.last?.id) { await conversation.markRead() }
    }

    private var feedContext: ChatFeedContext {
        var actions = partActions
        actions.sendFixedText = { text in Task { await composer.sendFixed(text) } }
        actions.retry = { id in Task { await conversation.retry(id) } }
        actions.continueStopped = { id in Task { await conversation.continueStopped(id) } }
        return ChatFeedContext(
            provider: conversation.feed?.conversation.actualProvider,
            artifacts: conversation.feed?.artifacts ?? [],
            actions: conversation.feed?.actions ?? [],
            isTurnRunning: conversation.isTurnRunning,
            hasEarlier: conversation.hasEarlier,
            staleLine: conversation.isStale ? ChatConversationModel.staleLine : nil,
            notice: nil,
            partActions: actions,
            rowActions: ChatRowActions(
                regenerate: { id in Task { await conversation.regenerate(id) } },
                edit: { composer.beginEditing($0) },
                selectBranch: { id in Task { await conversation.selectBranch(id) } },
                copy: partActions.copy,
                loadEarlier: { Task { await conversation.loadEarlier() } }
            )
        )
    }
}
