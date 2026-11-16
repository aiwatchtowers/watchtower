import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// What the feed's rows may do besides the parts' own actions.
public struct ChatRowActions {
    public var regenerate: (Int64) -> Void
    /// Starts editing an owner message (the composer takes its text).
    public var edit: (ChatFeed.Message) -> Void
    /// Shows the sibling branch with this message id.
    public var selectBranch: (Int64) -> Void
    public var copy: (String) -> Void
    public var loadEarlier: () -> Void

    public init(
        regenerate: @escaping (Int64) -> Void = { _ in },
        edit: @escaping (ChatFeed.Message) -> Void = { _ in },
        selectBranch: @escaping (Int64) -> Void = { _ in },
        copy: @escaping (String) -> Void = { _ in },
        loadEarlier: @escaping () -> Void = {}
    ) {
        self.regenerate = regenerate
        self.edit = edit
        self.selectBranch = selectBranch
        self.copy = copy
        self.loadEarlier = loadEarlier
    }
}

/// Everything the feed needs besides its messages. Embedded chats and Workchat build one without a `ChatClient`
/// (ruling F19).
public struct ChatFeedContext {
    public var provider: String?
    public var artifacts: [ChatFeed.Artifact]
    /// The feed's flat actions; the ones no approval part shows are drawn after the last message.
    public var actions: [ChatFeed.Action]
    public var isTurnRunning: Bool
    public var hasEarlier: Bool
    /// A subtle line while the feed is stale (events were lost; the fresh snapshot is on its way).
    public var staleLine: String?
    public var notice: String?
    public var partActions: ChatPartActions
    public var rowActions: ChatRowActions

    public init(
        provider: String? = nil,
        artifacts: [ChatFeed.Artifact] = [],
        actions: [ChatFeed.Action] = [],
        isTurnRunning: Bool = false,
        hasEarlier: Bool = false,
        staleLine: String? = nil,
        notice: String? = nil,
        partActions: ChatPartActions = ChatPartActions(),
        rowActions: ChatRowActions = ChatRowActions()
    ) {
        self.provider = provider
        self.artifacts = artifacts
        self.actions = actions
        self.isTurnRunning = isTurnRunning
        self.hasEarlier = hasEarlier
        self.staleLine = staleLine
        self.notice = notice
        self.partActions = partActions
        self.rowActions = rowActions
    }
}

/// The scrolling feed, driven by messages alone (ruling F19): the main chat passes its conversation model's messages,
/// embedded chats and Workchat pass theirs. It follows the newest message while the reader is at the bottom.
public struct ChatFeedView: View {
    let messages: [ChatFeed.Message]
    let context: ChatFeedContext

    public init(messages: [ChatFeed.Message], context: ChatFeedContext) {
        self.messages = messages
        self.context = context
    }

    public var body: some View {
        let rows = ChatFeedLayout.rows(messages: messages, actions: context.actions)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.large) {
                    if context.hasEarlier {
                        SystemRow(kind: .earlier(onLoad: context.rowActions.loadEarlier))
                    }
                    ForEach(rows) { row in
                        rowView(row).id(row.id)
                    }
                    if let staleLine = context.staleLine {
                        SystemRow(kind: .line(staleLine))
                    }
                    if let notice = context.notice {
                        SystemRow(kind: .notice(notice))
                    }
                }
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.medium)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: rows.last?.id) { _, last in
                guard let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
        .accessibilityIdentifier("chat.feed")
    }

    @ViewBuilder
    private func rowView(_ row: ChatFeedLayout.Row) -> some View {
        switch row {
        case let .message(message, parts):
            ChatMessageRow(message: message, parts: parts, context: partContext(message), rowActions: context.rowActions,
                           isTurnRunning: context.isTurnRunning)
        case .approvals(let actions):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                ForEach(actions) { action in
                    ApprovalPartView(payload: ChatApprovalPayload(action: action),
                                     context: partContext(messages.last ?? Self.placeholder))
                }
            }
        }
    }

    private func partContext(_ message: ChatFeed.Message) -> ChatPartContext {
        ChatPartContext(
            message: message,
            provider: context.provider,
            artifacts: context.artifacts,
            isAnswerable: isAnswerable(message.id),
            answerText: ownerReply(after: message.id),
            actions: context.partActions
        )
    }

    private func isAnswerable(_ id: Int64) -> Bool {
        guard !context.isTurnRunning, messages.last(where: { $0.role == "assistant" })?.id == id else { return false }
        return ownerReply(after: id) == nil
    }

    private func ownerReply(after id: Int64) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages[(index + 1)...].first { $0.role == "user" }?.text
    }

    private static let placeholder = ChatFeed.Message(id: 0, role: "assistant", text: "", createdAt: .distantPast)
}
