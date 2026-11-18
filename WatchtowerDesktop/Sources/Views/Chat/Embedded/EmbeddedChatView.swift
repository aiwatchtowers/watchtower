import AppKit
import ChatUI
import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// How roomy a chat is: tab-sized embedded chats use `.regular`; docks, the setup side panel, popovers and collapsible
/// sections `.compact`.
enum ChatDensity {
    case regular
    case compact

    /// The thread column; a compact chat uses its whole (narrow) width.
    var maxColumnWidth: CGFloat? { self == .regular ? 760 : nil }
    /// The thread's margins, as the app's own feed had them (the bottom one less the feed's 2 pt end mark).
    var margins: EdgeInsets {
        switch self {
        case .regular: EdgeInsets(top: Spacing.large, leading: Spacing.page, bottom: Spacing.medium + Spacing.tight,
                                  trailing: Spacing.page)
        case .compact: EdgeInsets(top: Spacing.regular, leading: Spacing.medium, bottom: Spacing.compact,
                                  trailing: Spacing.medium)
        }
    }

    /// The composer's growth limit for a chat that has no window-relative one.
    var composerMaxHeight: CGFloat { self == .regular ? 200 : 120 }
}

/// An embedded assistant chat (target, track, idea, meeting, onboarding, setup) drawn by ChatUI's feed (unified chat
/// spec §9.2) over its own engine (`EmbeddedChatCenter`, so leaving this view never stops a turn), then an optional
/// footer, then `ChatComposerBar`. Slots: `accessory` under a message (the target's action cards) and `footer` above
/// the composer (Approve all, quick replies, Continue/Skip).
struct EmbeddedChatView<Accessory: View, Footer: View>: View {
    let engine: EmbeddedChatEngine
    var density: ChatDensity = .regular
    let placeholder: String
    var dictationTargetID: String?
    /// Hides the composer while the surface offers other input instead
    /// (onboarding's quick replies).
    var showsComposer = true
    /// Esc in the composer; nil stops the running answer (a popover closes
    /// itself instead).
    var onEscape: (() -> Void)?
    /// Focus the composer when it appears.
    var autoFocus = false
    @ViewBuilder var accessory: (ChatThreadItem) -> Accessory
    @ViewBuilder var footer: () -> Footer
    @State private var artifact: ChatArtifactContent?

    var body: some View {
        let feed = EmbeddedChatFeed(engine: engine, density: density, accessory: accessory) { artifact = $0 }
        VStack(spacing: 0) {
            ChatUI.ChatFeedView(messages: feed.messages, context: feed.context(follows: true))
            footer()
            if showsComposer {
                EmbeddedChatComposer(engine: engine, placeholder: placeholder,
                                     dictationTargetID: dictationTargetID, density: density, onEscape: onEscape,
                                     autoFocus: autoFocus)
            }
        }
        .embeddedArtifactSheet($artifact)
        .macChatStyle(hooks: .app, look: .embedded)
    }
}

extension EmbeddedChatView where Accessory == EmptyView, Footer == EmptyView {
    init(
        engine: EmbeddedChatEngine,
        density: ChatDensity = .regular,
        placeholder: String,
        dictationTargetID: String? = nil,
        onEscape: (() -> Void)? = nil
    ) {
        self.init(engine: engine, density: density, placeholder: placeholder, dictationTargetID: dictationTargetID,
                  onEscape: onEscape, accessory: { _ in EmptyView() }, footer: { EmptyView() })
    }
}

/// The rows alone, with no scroll of their own — for a chat that sits
/// inside its pane's `ScrollView` (the idea/decision Discuss section, the
/// tuning panel). Its composer is docked outside that scroll
/// (`EmbeddedChatComposer`): the input's `NSScrollView` collapses inside a
/// SwiftUI `ScrollView`.
struct EmbeddedChatRows<Accessory: View>: View {
    let engine: EmbeddedChatEngine
    var density: ChatDensity = .compact
    @ViewBuilder var accessory: (ChatThreadItem) -> Accessory
    @State private var artifact: ChatArtifactContent?

    var body: some View {
        let feed = EmbeddedChatFeed(engine: engine, density: density, accessory: accessory) { artifact = $0 }
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ChatFeedRows(messages: feed.messages, context: feed.context(follows: false))
        }
        .embeddedArtifactSheet($artifact)
        .macChatStyle(hooks: .app, look: .embedded)
    }
}

extension EmbeddedChatRows where Accessory == EmptyView {
    init(engine: EmbeddedChatEngine) {
        self.init(engine: engine) { _ in EmptyView() }
    }
}

/// What ChatUI's feed draws for an embedded chat: the stored rows through `EmbeddedChatFeedAdapter`, the Mac's own
/// pieces under a message (the surface's accessory, a reply the surface could not use, the reviewed actions, a reply
/// whose end could not be saved, the remember and knowledge marks), and after the rows the streaming reply (its own
/// view, so only it re-renders on a delta), the queued message and, for an empty chat, the hint and starter prompts.
@MainActor
struct EmbeddedChatFeed<Accessory: View> {
    let engine: EmbeddedChatEngine
    let density: ChatDensity
    let accessory: (ChatThreadItem) -> Accessory
    let openArtifact: (ChatArtifactContent) -> Void
    /// The hint and starter prompts of an empty chat; off for a surface with its own (the tuning chat).
    var showsEmptyState = true

    static var queuedCaption: String { "Queued" }
    static var notSavedLine: String { "Not saved" }
    static var stoppedLine: String { "Stopped" }

    /// The streaming reply when it is the last row: drawn after the rows by its own view.
    private var streaming: (live: LiveTurn, item: ChatThreadItem)? {
        guard let live = engine.liveTurn, let last = engine.messages.last, last.id == live.messageID else { return nil }
        return (live, last)
    }

    /// The rows the feed lays out; the streaming reply is drawn in the footer instead.
    var messages: [ChatFeed.Message] {
        let rows = streaming == nil ? engine.messages : Array(engine.messages.dropLast())
        return EmbeddedChatFeedAdapter.messages(rows: rows, live: streaming == nil ? engine.liveTurn : nil)
    }

    func context(follows: Bool) -> ChatFeedContext {
        let items = Dictionary(engine.messages.map { ($0.id, $0) }) { _, last in last }
        let lastAssistantID = engine.messages.last { $0.message.isAssistant }?.id
        var context = ChatFeedContext(
            isTurnRunning: engine.isBusy,
            partActions: partActions(lastAssistantID: lastAssistantID),
            rowActions: rowActions
        )
        context.caption = { message in items[message.id].flatMap(Self.caption) }
        context.messageAccessory = { message in
            items[message.id].map { AnyView(extras(for: $0, lastAssistantID: lastAssistantID)) }
        }
        context.footer = AnyView(footer(lastAssistantID: lastAssistantID))
        context.compact = density == .compact
        context.columnMaxWidth = density.maxColumnWidth
        context.margins = density.margins
        context.lastMessageID = engine.messages.last?.id
        if follows {
            context.follow = ChatFeedFollow(conversationID: engine.spec.key.conversationID,
                                            liveMessageID: engine.liveTurn?.messageID)
        }
        return context
    }

    /// Copy only: an embedded chat has no Edit, Regenerate, branches or quoting.
    private var rowActions: ChatRowActions {
        var actions = ChatRowActions(copy: Self.copy)
        actions.allowsEdit = false
        actions.allowsRegenerate = false
        return actions
    }

    private func partActions(lastAssistantID: Int64?) -> ChatPartActions {
        let engine = engine
        var actions = ChatPartActions(
            // A question card's answers are an ordinary owner turn.
            sendFixedText: { _ = engine.send($0) },
            openURL: Self.open,
            copy: Self.copy,
            retry: { _ in engine.retry() },
            openArtifact: openArtifact
        )
        actions.reviewActions = { engine.reviewActions(messageID: $0) }
        actions.canRetry = { id in Self.offersRetry(engine: engine, messageID: id, lastAssistantID: lastAssistantID) }
        actions.offersContinue = false
        actions.showsSources = false
        return actions
    }

    /// Retry sits on the last failed reply only, and only while nothing runs.
    static func offersRetry(engine: EmbeddedChatEngine, messageID: Int64, lastAssistantID: Int64?) -> Bool {
        engine.canRetry && !engine.isBusy && messageID == lastAssistantID
    }

    /// "model · time" under a row.
    static func caption(_ item: ChatThreadItem) -> String {
        let time = item.message.createdDate.formatted(date: .omitted, time: .shortened)
        guard let model = item.message.model, !model.isEmpty else { return time }
        return "\(model) · \(time)"
    }

    @ViewBuilder
    private func extras(for item: ChatThreadItem, lastAssistantID: Int64?) -> some View {
        let engine = engine
        if item.message.isUser, engine.spec.showsRememberMarks {
            let body = ChatOwnerText.displayParts(item.message.text).body
            RememberMarkView(messageID: item.id, text: body)
            ChatKnowledgeMarkView(conversationID: item.message.conversationID, messageID: item.id, text: body)
        }
        // A reply whose error could not be written stays `partial` on disk: Retry where the chat offers it.
        if item.message.isAssistant, item.message.status == "partial", item.message.errorCode == nil,
           engine.liveTurn?.messageID != item.id {
            HStack(spacing: Spacing.regular) {
                if Self.offersRetry(engine: engine, messageID: item.id, lastAssistantID: lastAssistantID) {
                    Text(Self.notSavedLine).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { engine.retry() }.controlSize(.small)
                } else {
                    Text(Self.stoppedLine).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let failure = engine.postTurnResults[item.id]?.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Tone.warning)
        }
        accessory(item)
        if engine.reviewedMessageID == item.id {
            ChatActionReviewView(actions: engine.reviewedActions)
        }
    }

    @ViewBuilder
    private func footer(lastAssistantID: Int64?) -> some View {
        let engine = engine
        if showsEmptyState, engine.messages.isEmpty && !engine.isQueued {
            EmbeddedChatEmptyState(hint: engine.spec.emptyHint, prompts: engine.spec.starterPrompts) { prompt in
                if prompt.sendsImmediately {
                    engine.send(prompt.text)
                } else {
                    engine.draft = prompt.text
                }
            }
        }
        if let streaming {
            EmbeddedLiveRow(turn: streaming.live, item: streaming.item, partActions: partActions(lastAssistantID: nil),
                            rowActions: rowActions)
            extras(for: streaming.item, lastAssistantID: lastAssistantID)
        }
        if let queued = engine.queuedText {
            let message = ChatFeed.Message(id: -1, role: "user", text: queued, createdAt: .now)
            ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                           context: ChatPartContext(message: message), rowActions: rowActions, isTurnRunning: true,
                           caption: Self.queuedCaption)
                .opacity(0.6)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A link in a card: the system's handler for the schemes the chat allows.
    private static func open(_ url: URL) {
        if AllowedURLSchemes.permits(url) { NSWorkspace.shared.open(url) }
    }
}

/// The streaming reply: the only view that reads `LiveTurn.text`, so only it re-renders on a delta (render isolation).
private struct EmbeddedLiveRow: View {
    let turn: LiveTurn
    let item: ChatThreadItem
    let partActions: ChatPartActions
    let rowActions: ChatRowActions

    var body: some View {
        let message = EmbeddedChatFeedAdapter.messages(rows: [item], live: turn)[0]
        ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                       context: ChatPartContext(message: message, actions: partActions), rowActions: rowActions,
                       isTurnRunning: turn.isRunning)
            .id(ChatFeedLayout.rowID(item.id))
    }
}

/// The composer of an embedded chat: the draft lives on the engine (it
/// survives navigation), Stop also withdraws a queued message, and a
/// failure not tied to a message shows above the field.
struct EmbeddedChatComposer: View {
    @Bindable var engine: EmbeddedChatEngine
    let placeholder: String
    var dictationTargetID: String?
    var density: ChatDensity = .regular
    var onEscape: (() -> Void)?
    var autoFocus = false

    var body: some View {
        ChatComposerBar(
            status: status,
            onCancelQueued: { engine.cancelQueued() },
            input: ChatComposerField(
                text: $engine.draft,
                isStreaming: engine.isBusy,
                config: ChatComposerFieldConfig(
                    placeholder: placeholder,
                    maxHeight: density.composerMaxHeight,
                    dictationTargetID: dictationTargetID,
                    autoFocus: autoFocus
                ),
                onSend: { engine.sendDraft() },
                // Nothing stops a turn whose rows or end are being written.
                onStop: engine.isFinishing || engine.isStarting ? nil : { engine.stop() },
                onEscape: escape
            )
        )
        .macComposerStyle()
    }

    /// Esc: the surface's own (close the ⌘/ panel), else Stop.
    private func escape() {
        if let onEscape { onEscape() } else { engine.stop() }
    }

    private var status: ChatComposerStatus? {
        if engine.isQueued { return .queued }
        if engine.isApplyingChanges { return .finishing }
        return engine.bannerError.map { .error($0) }
    }
}

/// An embedded chat's empty state: what the chat is for, plus the surface's
/// starter prompts.
struct EmbeddedChatEmptyState: View {
    let hint: String
    let prompts: [ChatStarterPrompt]
    let onPrompt: (ChatStarterPrompt) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !prompts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(prompts) { prompt in
                        Button(prompt.title) { onPrompt(prompt) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 520)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Tells the center while this view shows `key`'s chat, so an engine no
    /// screen has shown for a while can be released. A key swapped in place
    /// (another tab, another record) hands the mark over.
    func embeddedChatVisibility(_ key: EmbeddedChatKey, in center: EmbeddedChatCenter) -> some View {
        onAppear { center.markShown(key) }
            .onDisappear { center.markHidden(key) }
            .onChange(of: key) { old, new in
                center.markHidden(old)
                center.markShown(new)
            }
    }
}
