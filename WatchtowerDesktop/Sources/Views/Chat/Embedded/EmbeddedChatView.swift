import SwiftUI
import AppKit
import WatchtowerCore

/// An embedded assistant chat (target, track, idea, meeting, onboarding,
/// setup) on the main chat's pieces: `ChatFeedView` with `ChatMessageRow` /
/// `LiveAssistantRow`, then an optional footer, then `ChatComposerBar`. The
/// engine lives in `EmbeddedChatCenter`, so leaving this view never stops a
/// turn. Slots: `accessory` under a message (the target's action cards) and
/// `footer` above the composer (Approve all, quick replies, Continue/Skip).
struct EmbeddedChatView<Accessory: View, Footer: View>: View {
    let engine: EmbeddedChatEngine
    var density: ChatDensity = .regular
    let placeholder: String
    var dictationTargetID: String?
    /// Hides the composer while the surface offers other input instead
    /// (onboarding's quick replies).
    var showsComposer = true
    @ViewBuilder var accessory: (ChatThreadItem) -> Accessory
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ChatFeedView(state: feedState, lastRowID: engine.messages.last?.id, density: density) {
                EmbeddedChatRows(engine: engine, accessory: accessory)
            }
            footer()
            if showsComposer {
                EmbeddedChatComposer(engine: engine, placeholder: placeholder,
                                     dictationTargetID: dictationTargetID, density: density)
            }
        }
    }

    private var feedState: ChatAutoScrollPolicy.ThreadState {
        .init(conversationID: engine.spec.key.conversationID, lastMessageID: engine.messages.last?.id,
              scrollTarget: nil, liveMessageID: engine.liveTurn?.messageID)
    }
}

extension EmbeddedChatView where Accessory == EmptyView, Footer == EmptyView {
    init(
        engine: EmbeddedChatEngine,
        density: ChatDensity = .regular,
        placeholder: String,
        dictationTargetID: String? = nil
    ) {
        self.init(engine: engine, density: density, placeholder: placeholder, dictationTargetID: dictationTargetID,
                  accessory: { _ in EmptyView() }, footer: { EmptyView() })
    }
}

/// The rows alone, with no scroll of their own — for a chat that sits
/// inside its pane's `ScrollView` (the idea/decision Discuss section). Its
/// composer is docked outside that scroll (`EmbeddedChatComposer`): the
/// input's `NSScrollView` collapses inside a SwiftUI `ScrollView`.
struct EmbeddedChatRows<Accessory: View>: View {
    let engine: EmbeddedChatEngine
    @ViewBuilder var accessory: (ChatThreadItem) -> Accessory

    var body: some View {
        if engine.messages.isEmpty && !engine.isQueued {
            EmbeddedChatEmptyState(hint: engine.spec.emptyHint, prompts: engine.spec.starterPrompts) { prompt in
                if prompt.sendsImmediately {
                    engine.send(prompt.text)
                } else {
                    engine.draft = prompt.text
                }
            }
        }
        ForEach(engine.messages) { item in
            row(item).id(item.id)
            if let failure = engine.postTurnResults[item.id]?.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            accessory(item)
        }
        if let queued = engine.queuedText {
            VStack(alignment: .trailing, spacing: 2) {
                UserMessageBubble(text: queued).opacity(0.6)
                Text("Queued").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func row(_ item: ChatThreadItem) -> some View {
        if let live = engine.liveTurn, live.messageID == item.id {
            LiveAssistantRow(turn: live)
        } else {
            ChatMessageRow(item: item, isLast: item.id == engine.messages.last?.id, isEditing: false,
                           actions: .embedded(copy: Self.copy, retry: retry(for: item),
                                              answerQuestion: answerQuestion(for: item)),
                           questionAnswer: ownerReply(after: item))
                .equatable()
        }
    }

    /// Retry sits on the last failed reply only, and only while nothing runs.
    /// A reply whose error could not be written stays `partial` on disk.
    private func retry(for item: ChatThreadItem) -> ((Int64) -> Void)? {
        guard engine.canRetry, !engine.isBusy, item.message.status != "complete",
              item.id == engine.messages.last(where: { $0.message.isAssistant })?.id else { return nil }
        return { _ in engine.retry() }
    }

    /// A question card is answered from the latest reply only, while
    /// nothing runs; the answer is an ordinary owner turn.
    private func answerQuestion(for item: ChatThreadItem) -> ((String) -> Void)? {
        let rows = engine.messages.map(\.message)
        guard let index = rows.firstIndex(where: { $0.id == item.id }),
              ChatQuestionThread.isAnswerable(at: index, in: rows, busy: engine.isBusy) else { return nil }
        return { _ = engine.send($0) }
    }

    /// The owner's words right after `item` — a question card's answer.
    private func ownerReply(after item: ChatThreadItem) -> String? {
        let rows = engine.messages.map(\.message)
        guard let index = rows.firstIndex(where: { $0.id == item.id }) else { return nil }
        return ChatQuestionThread.ownerReply(after: index, in: rows)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension EmbeddedChatRows where Accessory == EmptyView {
    init(engine: EmbeddedChatEngine) {
        self.init(engine: engine) { _ in EmptyView() }
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

    // Every closure here is a named role (send, stop, escape); none is "the" trailing one.
    // swiftlint:disable trailing_closure
    var body: some View {
        ChatComposerBar(
            status: status,
            onCancelQueued: { engine.cancelQueued() },
            input: ChatComposerField(
                text: $engine.draft,
                isStreaming: engine.isBusy,
                onSend: { engine.sendDraft() },
                onStop: { engine.stop() },
                placeholder: placeholder,
                dictationTargetID: dictationTargetID,
                maxHeight: density.composerMaxHeight,
                onEscape: { engine.stop() }
            )
        )
    }
    // swiftlint:enable trailing_closure

    private var status: ChatComposerStatus? {
        if engine.isQueued { return .queued }
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
