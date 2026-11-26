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
    /// "Ask about this": a passage of an answer to quote in the next message (the Mac selects it in the feed, the
    /// phone picks it in a sheet); nil turns quoting off (embedded chats).
    public var quote: ((String) -> Void)?
    /// Whether an owner message offers Edit and a reply Regenerate; a chat whose engine has neither (embedded chats,
    /// Workchat) turns them off.
    public var allowsEdit = true
    public var allowsRegenerate = true
    /// Whether a row offers Copy; off for a feed whose rows only show (Workchat).
    public var allowsCopy = true

    public init(
        regenerate: @escaping (Int64) -> Void = { _ in },
        edit: @escaping (ChatFeed.Message) -> Void = { _ in },
        selectBranch: @escaping (Int64) -> Void = { _ in },
        copy: @escaping (String) -> Void = { _ in },
        loadEarlier: @escaping () -> Void = {},
        quote: ((String) -> Void)? = nil
    ) {
        self.regenerate = regenerate
        self.edit = edit
        self.selectBranch = selectBranch
        self.copy = copy
        self.loadEarlier = loadEarlier
        self.quote = quote
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
    /// The turn running now: an approval card it waits on is outlined.
    public var runningTurnID: String?
    public var hasEarlier: Bool
    /// A subtle line while the feed is stale (events were lost; the fresh snapshot is on its way).
    public var staleLine: String?
    public var notice: String?
    public var partActions: ChatPartActions
    public var rowActions: ChatRowActions
    /// What the app draws under a message (the Mac's "Approve all" and action review); nil draws nothing.
    public var messageAccessory: ((ChatFeed.Message) -> AnyView?)?
    /// What the app draws over a message (a subagent run's "Task" and "Report" headings); nil draws nothing.
    public var messageHeader: ((ChatFeed.Message) -> AnyView?)?
    /// What the app draws after the last message (the Mac's cards of an interrupted turn).
    public var footer: AnyView?
    /// What the app draws before the first message (the tuning chat's figures line); nil draws nothing.
    public var header: AnyView?
    /// A message to scroll to once it is loaded (a search hit); nil follows the newest message.
    public var focusMessageID: Int64?
    /// The line under a message, after its actions (the Mac's embedded chats: "model · time"; Workchat: the time and
    /// "via Watchtower"); nil draws none.
    public var caption: ((ChatFeed.Message) -> String?)?
    /// Draws the line under a message instead of `caption` (Workchat's "via Watchtower" and time).
    public var captionView: ((ChatFeed.Message) -> AnyView?)?
    /// What sits in the owner's bubble over the text (Workchat: the ask an answer went to).
    public var ownerHeader: ((ChatFeed.Message) -> AnyView?)?
    /// The newest message when it is drawn outside `messages` (an embedded chat's streaming reply, in the footer); it,
    /// not the last of `messages`, keeps a hover-only actions row shown.
    public var lastMessageID: Int64?
    /// The column's margins; nil keeps the feed's own.
    public var margins: EdgeInsets?
    /// How a `system` message is drawn (Workchat's notices, subagent cards and Watchtower's own lines); nil draws its
    /// text as one centred caption line.
    public var systemRow: ((ChatFeed.Message) -> AnyView)?
    /// Tighter rows and margins for a narrow chat (a dock, a popover, a side panel).
    public var compact = false
    /// The widest the message column grows (centred); nil fills the width.
    public var columnMaxWidth: CGFloat?
    /// Follows the newest content only while the reader is at the bottom, stops when they scroll up and offers "Jump
    /// to latest" (`ChatFollowTracker`); nil keeps the plain behaviour (every new message scrolls into view).
    public var follow: ChatFeedFollow?
    /// Colours the agent's refs, hashes, commands, dates and, with a resolver, file paths as an IDE colours code
    /// (Workchat, spec 2026-11-24-workchat-polish §2, spec 2026-11-26-chat-text-highlights); nil keeps the agent's
    /// text plain (the AI chat, the phone).
    public var agentTextHighlighting: AgentTextHighlighting?

    public init(
        provider: String? = nil,
        artifacts: [ChatFeed.Artifact] = [],
        actions: [ChatFeed.Action] = [],
        isTurnRunning: Bool = false,
        hasEarlier: Bool = false,
        staleLine: String? = nil,
        notice: String? = nil,
        partActions: ChatPartActions = ChatPartActions(),
        rowActions: ChatRowActions = ChatRowActions(),
        messageAccessory: ((ChatFeed.Message) -> AnyView?)? = nil,
        footer: AnyView? = nil,
        focusMessageID: Int64? = nil,
        runningTurnID: String? = nil
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
        self.messageAccessory = messageAccessory
        self.footer = footer
        self.focusMessageID = focusMessageID
        self.runningTurnID = runningTurnID
    }
}

/// What the feed follows (`ChatFeedContext.follow`): the conversation (a switch lands at the bottom) and the message a
/// running turn streams into (its start pins the feed to the bottom again).
public struct ChatFeedFollow {
    public var conversationID: Int64?
    public var liveMessageID: Int64?
    /// Short content sits at the bottom of the viewport (Workchat); off, it starts at the top (embedded chats).
    public var anchorsBottom = false
    /// Scrolling to the top loads earlier messages by itself (Workchat's window), as the "Load earlier" row would.
    public var loadsEarlierAtTop = false
    /// The reader came back to the newest content (or left it): Workchat lets its window go when it follows again.
    public var onFollowingChange: ((Bool) -> Void)?
    /// The feed scrolled to `ChatFeedContext.focusMessageID`: the screen may let the focus go.
    public var onFocusApplied: (() -> Void)?

    public init(conversationID: Int64?, liveMessageID: Int64? = nil) {
        self.conversationID = conversationID
        self.liveMessageID = liveMessageID
    }
}

/// The scrolling feed, driven by messages alone (ruling F19): the main chat passes its conversation model's messages,
/// embedded chats and Workchat pass theirs. It follows the newest message while the reader is at the bottom.
public struct ChatFeedView: View {
    let messages: [ChatFeed.Message]
    let context: ChatFeedContext
    /// The messages' parts from the last pass: a streaming update re-derives only the message it changed.
    @State private var partsCache = ChatMessagePartsCache()

    public init(messages: [ChatFeed.Message], context: ChatFeedContext) {
        self.messages = messages
        self.context = context
    }

    public var body: some View {
        let rows = ChatFeedLayout.rows(messages: messages, actions: context.actions, cache: partsCache)
        Group {
            if let follow = context.follow {
                ChatFollowingScroll(rows: rows, messages: messages, context: context, follow: follow)
            } else {
                plainScroll(rows)
            }
        }
        .modifier(ChatFeedQuoteSupport(onQuote: context.rowActions.quote))
        .accessibilityIdentifier("chat.feed")
    }

    private func plainScroll(_ rows: [ChatFeedLayout.Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                ChatFeedColumn(context: context) {
                    ChatFeedRows(rows: rows, messages: messages, context: context)
                }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: rows.last?.id) { _, last in
                guard let last, focusRow(in: rows) == nil else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onChange(of: focusRow(in: rows), initial: true) { _, focus in
                guard let focus else { return }
                proxy.scrollTo(focus, anchor: .center)
            }
        }
    }

    /// The focused message's row id, once that message is loaded.
    private func focusRow(in rows: [ChatFeedLayout.Row]) -> String? {
        guard let focusMessageID = context.focusMessageID else { return nil }
        let id = ChatFeedLayout.rowID(focusMessageID)
        return rows.contains { $0.id == id } ? id : nil
    }
}

/// The feed's column: the rows' spacing and margins, at most `columnMaxWidth` wide and centred.
struct ChatFeedColumn<Content: View>: View {
    let context: ChatFeedContext
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVStack(alignment: .leading, spacing: context.compact ? Spacing.cozy : Spacing.large) {
            content()
        }
        .padding(context.margins ?? EdgeInsets(
            top: context.compact ? Spacing.regular : Spacing.medium,
            leading: context.compact ? Spacing.cozy : Spacing.large,
            bottom: context.compact ? Spacing.regular : Spacing.medium,
            trailing: context.compact ? Spacing.cozy : Spacing.large
        ))
        .frame(maxWidth: context.columnMaxWidth ?? .infinity)
        .frame(maxWidth: .infinity)
    }
}

/// The feed's rows with no scroll of their own: for a chat that sits inside its pane's own scroll view (an idea's
/// Discuss section, the tuning panel). `ChatFeedView` draws the same rows in its scroll view.
public struct ChatFeedRows: View {
    /// The rows `ChatFeedView` already built; nil builds them here, over this view's own parts cache.
    private let builtRows: [ChatFeedLayout.Row]?
    let messages: [ChatFeed.Message]
    let context: ChatFeedContext
    @State private var partsCache = ChatMessagePartsCache()

    public init(messages: [ChatFeed.Message], context: ChatFeedContext) {
        self.builtRows = nil
        self.messages = messages
        self.context = context
    }

    init(rows: [ChatFeedLayout.Row], messages: [ChatFeed.Message], context: ChatFeedContext) {
        self.builtRows = rows
        self.messages = messages
        self.context = context
    }

    private var rows: [ChatFeedLayout.Row] {
        builtRows ?? ChatFeedLayout.rows(messages: messages, actions: context.actions, cache: partsCache)
    }

    public var body: some View {
        if context.hasEarlier {
            SystemRow(kind: .earlier(onLoad: context.rowActions.loadEarlier))
        }
        if let header = context.header {
            header
        }
        ForEach(rows) { row in
            if case let .message(message, _) = row, let heading = context.messageHeader?(message) {
                heading
            }
            rowView(row).id(row.id)
            if case let .message(_, parts) = row, let approveAll = context.partActions.approvals.approveAll,
               let turn = ApproveAllRow.turn(of: approvalActions(parts)) {
                ApproveAllRow(turnID: turn, approveAll: approveAll)
            }
            if case let .message(message, _) = row, let accessory = context.messageAccessory?(message) {
                accessory
            }
        }
        if let footer = context.footer {
            footer
        }
        if let staleLine = context.staleLine {
            SystemRow(kind: .line(staleLine))
        }
        if let notice = context.notice {
            SystemRow(kind: .notice(notice))
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatFeedLayout.Row) -> some View {
        switch row {
        case let .message(message, _) where message.role == ChatMessageRow.systemRole:
            if let systemRow = context.systemRow {
                systemRow(message)
            } else {
                SystemRow(kind: .line(message.text))
            }
        case let .message(message, parts):
            ChatMessageRow(message: message, parts: parts, context: partContext(message), rowActions: context.rowActions,
                           isTurnRunning: context.isTurnRunning, caption: context.caption?(message),
                           captionView: context.captionView?(message), ownerHeader: context.ownerHeader?(message),
                           isLast: message.id == (context.lastMessageID ?? messages.last?.id))
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
            isAnswerable: ChatFeedLayout.isAnswerable(message.id, in: messages, isTurnRunning: context.isTurnRunning),
            answerText: ChatFeedLayout.ownerReply(after: message.id, in: messages),
            runningTurnID: context.runningTurnID,
            actions: context.partActions,
            agentTextHighlighting: context.agentTextHighlighting
        )
    }

    /// A reply's approval parts as the cards draw them (the screen's row, else the payload).
    private func approvalActions(_ parts: [ChatPart]) -> [ChatAgentAction] {
        let services = context.partActions.approvals
        return parts.compactMap { part in
            guard part.kind == ChatPartKind.approval,
                  let payload = try? part.decodePayload(ChatApprovalPayload.self) else { return nil }
            return services.resolve?(payload) ?? ChatAgentAction(payload: payload)
        }
    }

    private static let placeholder = ChatFeed.Message(id: 0, role: "assistant", text: "", createdAt: .distantPast)
}
