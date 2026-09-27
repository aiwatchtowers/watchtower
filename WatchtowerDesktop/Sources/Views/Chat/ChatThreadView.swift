import SwiftUI
import AppKit
import WatchtowerCore

/// Frame of the bottom sentinel row in the thread scroll view's named
/// coordinate space; nil when nothing has published one yet.
private struct ChatBottomSentinelFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Reference box for the sentinel's last published frame — mutating it does
/// not invalidate the view, unlike a plain `@State CGRect?` (the
/// `NowLineFrameBox` precedent).
private final class ChatBottomFrameBox {
    var value: CGRect?
}

/// The centered thread column (spec §3.1, max ~760 pt). Reads `liveTurn`
/// identity only; its text is read by `LiveAssistantRow` alone.
struct ChatThreadView: View {
    @Bindable var chatVM: ChatViewModel
    let ownerName: String

    /// True while the viewport sits at (or within `ChatAutoScrollPolicy
    /// .bottomThreshold` of) the true bottom — the only state a streaming
    /// delta or a new message consults before pulling the view down. Starts
    /// `true` so opening a conversation lands at the bottom as before.
    @State private var isFollowing = true
    @State private var lastBottomFrame = ChatBottomFrameBox()
    /// Last conversation the bottom-follow logic reset for — a conversation
    /// switch always lands at the bottom, ignoring whatever `isFollowing`
    /// happened to be left over from the previous conversation's scroll
    /// position (`ChatThreadView` keeps its `@State` across a `select`).
    @State private var trackedConversationID: Int64?
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
                            row(item, proxy: proxy).id(item.id)
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
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ChatBottomSentinelFramePreferenceKey.self) { frame in
                    lastBottomFrame.value = frame
                    updateFollowState(viewportHeight: viewport.size.height)
                }
                // The classification depends on both inputs — a height-only
                // resize keeps the sentinel's frame byte-identical in the
                // scroll space, so the preference alone would go stale (the
                // `CalendarEventsView` now-line precedent).
                .onChange(of: viewport.size.height) { _, height in
                    updateFollowState(viewportHeight: height)
                }
                .overlay(alignment: .bottom) { jumpToLatestButton(proxy: proxy) }
                .onChange(of: chatVM.thread.last?.id) {
                    if trackedConversationID != chatVM.conversationID {
                        trackedConversationID = chatVM.conversationID
                        isFollowing = true
                    }
                    if isFollowing, let last = chatVM.thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: chatVM.scrollTarget) {
                    if let target = chatVM.scrollTarget { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChatBottomSentinelFramePreferenceKey.self,
                        value: geo.frame(in: .named(Self.scrollSpace))
                    )
                }
            )
            .id(Self.bottomSentinelID)
    }

    /// Derives `isFollowing` from the sentinel's last published frame — how
    /// far its top edge sits below the visible viewport's bottom edge.
    private func updateFollowState(viewportHeight: CGFloat) {
        guard let frame = lastBottomFrame.value, viewportHeight > 0 else { return }
        let distance = max(0, frame.minY - viewportHeight)
        let following = ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: distance)
        if following != isFollowing { isFollowing = following }
    }

    /// Shown only once the user has scrolled away from the bottom; jumping
    /// re-enables following so the next delta resumes tracking it.
    @ViewBuilder
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        if !isFollowing {
            Button {
                isFollowing = true
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
    private func row(_ item: ChatThreadItem, proxy: ScrollViewProxy) -> some View {
        if let live = chatVM.liveTurn, live.messageID == item.id {
            LiveAssistantRow(turn: live, onOpenArtifact: { chatVM.openArtifact(key: $0) },
                             onStreamingTextChanged: { text in
                                 chatVM.updateLiveArtifacts(streamingText: text)
                                 if isFollowing { proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom) }
                             })
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
            openArtifact: { chatVM.openArtifact(key: $0) }
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
