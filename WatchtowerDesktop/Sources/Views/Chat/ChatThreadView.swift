import SwiftUI
import AppKit
import WatchtowerCore

/// Frame of the thread content in the thread scroll view's named coordinate
/// space; nil when nothing has published one yet.
private struct ChatContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Reference box for the follow tracker — feeding it a measurement does not
/// invalidate the view, unlike a plain `@State` (the `NowLineFrameBox`
/// precedent); `isFollowing` mirrors the one bit the view renders.
private final class ChatFollowTrackerBox {
    var tracker = ChatFollowTracker()
}

/// The centered thread column (spec §3.1, max ~760 pt). Reads `liveTurn`
/// identity only; its text is read by `LiveAssistantRow` alone.
struct ChatThreadView: View {
    @Bindable var chatVM: ChatViewModel
    let ownerName: String

    /// Whether the view tracks the latest content — every content growth
    /// (streamed text, a tool step, an artifact block, a new row) pulls a
    /// following view down; a user scroll up stops it (`ChatFollowTracker`).
    /// Starts `true` so opening a conversation lands at the bottom. Mirrors
    /// `follow.tracker.following`.
    @State private var isFollowing = true
    @State private var follow = ChatFollowTrackerBox()
    private static let bottomSentinelID = "chat-bottom-sentinel"
    private static let scrollSpace = "chat-thread-scroll"

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if chatVM.thread.isEmpty {
                            ChatEmptyState(ownerName: ownerName, onPrompt: usePrompt)
                        }
                        ForEach(chatVM.thread) { item in
                            row(item).id(item.id)
                            actionCards(forTurn: item.message.turnID)
                        }
                        unattachedActionCards
                        if chatVM.isWaitingForSession {
                            Text("Waiting for a free chat session…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        errors
                        bottomSentinel
                    }
                    // No bottom padding: the sentinel's own height is it, so
                    // scrolling to the sentinel lands at the content's true
                    // bottom and the measured distance settles at 0.
                    .padding(.top, 16)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    // Measured on the whole content, not a trailing sentinel:
                    // the content frame is always laid out, while a
                    // `LazyVStack` row off the visible range may never publish.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ChatContentFramePreferenceKey.self,
                                value: geo.frame(in: .named(Self.scrollSpace))
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ChatContentFramePreferenceKey.self) { frame in
                    guard let frame else { return }
                    updateFollowState(.init(contentTop: frame.minY, contentHeight: frame.height,
                                            viewportHeight: viewport.size.height), proxy: proxy)
                }
                // The decision depends on both inputs — a height-only resize
                // keeps the content frame byte-identical in the scroll space,
                // so the preference alone would go stale (the
                // `CalendarEventsView` now-line precedent).
                .onChange(of: viewport.size.height) { _, height in
                    guard let last = follow.tracker.lastMetrics else { return }
                    updateFollowState(.init(contentTop: last.contentTop, contentHeight: last.contentHeight,
                                            viewportHeight: height), proxy: proxy)
                }
                .overlay(alignment: .bottom) { jumpToLatestButton(proxy: proxy) }
                // One handler for switch/jump/turn start/new row, so a ⌘K hit
                // that also switches into a streaming conversation lands on
                // the hit whatever order separate handlers would have fired in.
                // `initial`: the view can mount together with a ⌘K hit (opened
                // from a project page); the initial call passes old == new.
                .onChange(of: threadState, initial: true) { old, new in
                    let change = old == new
                        ? ChatAutoScrollPolicy.mountChange(new)
                        : ChatAutoScrollPolicy.threadChange(from: old, to: new)
                    handleThreadChange(change, proxy: proxy)
                }
            }
        }
    }

    /// Scroll target for "the very bottom" (and the thread's bottom margin);
    /// carries no measurement.
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 16)
            .id(Self.bottomSentinelID)
    }

    private var threadState: ChatAutoScrollPolicy.ThreadState {
        .init(conversationID: chatVM.conversationID, lastMessageID: chatVM.thread.last?.id,
              scrollTarget: chatVM.scrollTarget, liveMessageID: chatVM.liveTurn?.messageID)
    }

    private func handleThreadChange(_ change: ChatAutoScrollPolicy.ThreadChange, proxy: ScrollViewProxy) {
        switch change {
        case let .jumpToMessage(target):
            follow.tracker.restartTracking(following: false)
            syncFollowing()
            proxy.scrollTo(target, anchor: .center)
            chatVM.consumeScrollTarget()
        case .switchedConversation:
            follow.tracker.restartTracking(following: true)
            syncFollowing()
            if let last = chatVM.thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
        case .turnStarted:
            follow.tracker.repinToLatest()
            syncFollowing()
            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
        case .newLastRow:
            if isFollowing, let last = chatVM.thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
        case .none:
            break
        }
    }

    /// Feeds one content measurement to the tracker and pulls a following
    /// view down when the content grew under it.
    private func updateFollowState(_ current: ChatAutoScrollPolicy.Metrics, proxy: ScrollViewProxy) {
        guard current.viewportHeight > 0 else { return }
        let pull = follow.tracker.observeMeasurement(current)
        syncFollowing()
        if pull { proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom) }
    }

    private func syncFollowing() {
        if follow.tracker.following != isFollowing { isFollowing = follow.tracker.following }
    }

    /// Shown only once the user has scrolled away from the bottom; jumping
    /// re-enables following so the next delta resumes tracking it.
    @ViewBuilder
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        if !isFollowing {
            Button {
                follow.tracker.repinToLatest()
                syncFollowing()
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
                }
            } label: {
                Label("Jump to latest", systemImage: "arrow.down")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func row(_ item: ChatThreadItem) -> some View {
        if let live = chatVM.liveTurn, live.messageID == item.id {
            LiveAssistantRow(turn: live, onOpenArtifact: { chatVM.openArtifact(key: $0) },
                             onOpenSources: { chatVM.openSources(messageID: live.messageID, sources: $0) },
                             onStreamingTextChanged: { chatVM.updateLiveArtifacts(streamingText: $0) })
        } else {
            ChatMessageRow(item: item, isLast: item.id == chatVM.thread.last?.id,
                           isEditing: chatVM.editingMessageID == item.id, actions: actions,
                           artifactVersions: chatVM.artifactVersionsByMessage[item.id] ?? [:])
                .equatable()
        }
    }

    private var actions: ChatRowActions {
        ChatRowActions(
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            regenerate: { chatVM.regenerate(messageID: $0) },
            retry: { chatVM.retry(messageID: $0) },
            continueStopped: { chatVM.continueStopped(messageID: $0) },
            showVariant: { id, offset in
                if let target = chatVM.variant(of: id, offset: offset) { chatVM.selectVariant(messageID: target) }
            },
            beginEdit: { chatVM.editingMessageID = $0 },
            submitEdit: { chatVM.edit(messageID: $0, newText: $1) },
            cancelEdit: { chatVM.editingMessageID = nil },
            openArtifact: { chatVM.openArtifact(key: $0) },
            openSources: { chatVM.openSources(messageID: $0, sources: $1) }
        )
    }

    private func usePrompt(_ prompt: ChatStarterPrompt) {
        if prompt.sendsImmediately {
            chatVM.send(text: prompt.text)
        } else {
            chatVM.draft = prompt.text
        }
    }

    @ViewBuilder
    private func actionCards(forTurn turn: String) -> some View {
        if !turn.isEmpty {
            let cards = chatVM.actionFeed.cards(forTurn: turn)
            if cards.filter(\.isPending).count >= 2 {
                Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                    .font(.caption)
            }
            ForEach(cards) { action in agentActionCard(action) }
        }
    }

    /// Proposals whose turn never persisted a message — unreachable otherwise.
    @ViewBuilder
    private var unattachedActionCards: some View {
        let orphans = AgentActionFeed.unattached(
            rows: chatVM.actionFeed.rows,
            messageTurnIDs: Set(chatVM.thread.map(\.message.turnID).filter { !$0.isEmpty })
        )
        if !orphans.isEmpty {
            Text("Proposals from an interrupted turn").font(.caption).foregroundStyle(.secondary)
            ForEach(orphans) { action in agentActionCard(action) }
        }
    }

    @ViewBuilder
    private var errors: some View {
        if let error = chatVM.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if let persist = chatVM.liveTurn?.persistError {
            Text(persist).font(.caption).foregroundStyle(.red)
        }
        if let err = chatVM.actionFeed.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    private func agentActionCard(_ action: AgentAction) -> some View {
        AgentActionCardView(
            action: action,
            inFlight: chatVM.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chatVM.actionFeed.approve(action.id) } },
            onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
            onRetry: { Task { await chatVM.actionFeed.retry(action.id) } }
        )
    }
}
