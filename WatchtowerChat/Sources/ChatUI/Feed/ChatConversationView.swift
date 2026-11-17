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
    var composerFiles: ChatComposerShellFiles?
    var focusMessageID: Int64?

    public init(
        conversation: ChatConversationModel,
        composer: ChatComposerModel,
        partActions: ChatPartActions,
        onAttach: (() -> Void)? = nil
    ) {
        self.conversation = conversation
        self.composer = composer
        self.partActions = partActions
        self.onAttach = onAttach
    }

    /// With the shell's own files in the composer's chips (`ChatComposerView.shellFiles`) and a message to show first
    /// (a search hit: the feed pages back to it and scrolls to it).
    public init(
        conversation: ChatConversationModel,
        composer: ChatComposerModel,
        partActions: ChatPartActions,
        onAttach: (() -> Void)?,
        composerFiles: ChatComposerShellFiles?,
        focusMessageID: Int64?
    ) {
        self.conversation = conversation
        self.composer = composer
        self.partActions = partActions
        self.onAttach = onAttach
        self.composerFiles = composerFiles
        self.focusMessageID = focusMessageID
    }

    public var body: some View {
        VStack(spacing: 0) {
            ChatFeedView(messages: conversation.messages, context: feedContext)
            ChatComposerView(model: composer, field: ChatComposerFieldConfig(placeholder: composer.placeholder),
                             onAttach: onAttach, shellFiles: composerFiles)
        }
        .onAppear {
            if let focusMessageID { conversation.focusMessageID = focusMessageID }
            conversation.start()
        }
        .task(id: conversation.messages.first?.id) { await conversation.followFocus() }
        .onDisappear { conversation.stop() }
        .task(id: conversation.messages.last?.id) { await conversation.markRead() }
    }

    private var feedContext: ChatFeedContext {
        conversation.feedContext(composer: composer, partActions: partActions)
    }
}

extension ChatConversationModel {
    /// The feed's context for this conversation: its rows' turn operations through this model, the composer's
    /// fixed sends, edits and quotes, and the screen's own part actions. Shared by `ChatConversationView` and a shell
    /// that puts its own composer under the feed (the Mac's window).
    public func feedContext(composer: ChatComposerModel, partActions: ChatPartActions) -> ChatFeedContext {
        let conversation = self
        var actions = partActions
        actions.sendFixedText = { text in Task { await composer.sendFixed(text) } }
        actions.retry = { id in Task { await conversation.retry(id) } }
        actions.continueStopped = { id in Task { await conversation.continueStopped(id) } }
        var rowActions = ChatRowActions(copy: partActions.copy)
        rowActions.regenerate = { id in Task { await conversation.regenerate(id) } }
        rowActions.edit = composer.beginEditing
        rowActions.selectBranch = { id in Task { await conversation.selectBranch(id) } }
        rowActions.loadEarlier = { Task { await conversation.loadEarlier() } }
        rowActions.quote = composer.addQuote
        return ChatFeedContext(
            provider: conversation.feed?.conversation.actualProvider,
            artifacts: conversation.feed?.artifacts ?? [],
            actions: conversation.feed?.actions ?? [],
            isTurnRunning: conversation.isTurnRunning,
            hasEarlier: conversation.hasEarlier,
            staleLine: conversation.isStale ? Self.staleLine : nil,
            notice: nil,
            partActions: actions,
            rowActions: rowActions,
            focusMessageID: conversation.focusMessageID
        )
    }
}
