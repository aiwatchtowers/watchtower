import SwiftUI
import AppKit
import WatchtowerCore

/// The centered thread column (spec §3.1, max ~760 pt) on the shared
/// `ChatFeedView`. Reads `liveTurn` identity only; its text is read by
/// `LiveAssistantRow` alone.
struct ChatThreadView: View {
    @Bindable var chatVM: ChatViewModel
    @Environment(AppState.self) private var appState
    let ownerName: String

    var body: some View {
        ChatFeedView(state: threadState, lastRowID: chatVM.thread.last?.id,
                     selectionQuote: selectionQuote,
                     onScrollTargetConsumed: { chatVM.consumeScrollTarget() }, content: {
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
            ChatErrorStrip(chatVM: chatVM)
        })
    }

    /// "Ask about this" on a selected passage: it joins the composer's
    /// quote batch (`ChatViewModel.addQuote`), which focuses the composer.
    private var selectionQuote: ChatFeedSelectionQuote {
        ChatFeedSelectionQuote { chatVM.addQuote($0, comment: "") }
    }

    private var threadState: ChatAutoScrollPolicy.ThreadState {
        .init(conversationID: chatVM.conversationID, lastMessageID: chatVM.thread.last?.id,
              scrollTarget: chatVM.scrollTarget, liveMessageID: chatVM.liveTurn?.messageID)
    }

    @ViewBuilder
    private func row(_ item: ChatThreadItem) -> some View {
        if let live = chatVM.liveTurn, live.messageID == item.id {
            LiveAssistantRow(turn: live, onOpenArtifact: { chatVM.openArtifact(key: $0) },
                             onOpenSources: { chatVM.openSources(messageID: live.messageID, sources: $0) },
                             onStreamingTextChanged: { chatVM.updateLiveArtifacts(streamingText: $0) })
        } else {
            ChatMessageRow(item: item, isLast: item.id == chatVM.thread.last?.id,
                           isEditing: chatVM.editingMessageID == item.id, actions: actions(for: item),
                           artifactVersions: chatVM.artifactVersionsByMessage[item.id] ?? [:],
                           questionAnswer: ownerReply(after: item))
                .equatable()
        }
    }

    /// A question card is answered from the latest reply only, while no
    /// turn runs.
    private func actions(for item: ChatThreadItem) -> ChatRowActions {
        var actions = baseActions
        let rows = chatVM.thread.map(\.message)
        if let index = rows.firstIndex(where: { $0.id == item.id }),
           ChatQuestionThread.isAnswerable(at: index, in: rows, busy: chatVM.isStreaming) {
            actions.answerQuestion = { _ = chatVM.send(text: $0, keepsComposer: true) }
        }
        return actions
    }

    /// The owner's words right after `item` — a question card's answer.
    private func ownerReply(after item: ChatThreadItem) -> String? {
        let rows = chatVM.thread.map(\.message)
        guard let index = rows.firstIndex(where: { $0.id == item.id }),
              let text = ChatQuestionThread.ownerReply(after: index, in: rows) else { return nil }
        return ChatTurnComposer.displayParts(text).body
    }

    private var baseActions: ChatRowActions {
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
            if chatVM.actionFeed.bulkApprovable(forTurn: turn).count >= 2 {
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

    /// A card a live step waits on (`tool_wait`, same action id) is outlined,
    /// so the step's "see the approval card below" points at one card.
    private func agentActionCard(_ action: AgentAction) -> some View {
        let awaited = chatVM.liveTurn?.waitingActionIDs.contains(action.id) ?? false
        return AgentActionCardView(
            action: action,
            inFlight: chatVM.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chatVM.actionFeed.approve(action.id, shownArgs: action.argsJSON) } },
            onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
            onRetry: { Task { await chatVM.actionFeed.retry(action.id) } },
            gestureError: chatVM.actionFeed.rowErrors[action.id],
            onApproveEdited: { patch in Task { await chatVM.actionFeed.approve(action.id, shownArgs: action.argsJSON, patch: patch) } },
            onReconnectSlack: { id in await appState.reconnectSlack(accountID: id) },
            sessionHoldsCall: appState.chatSessionPool?.holdsSessionCall(action) ?? false
        )
        .overlay {
            if awaited {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange, lineWidth: 1.5)
            }
        }
    }
}

/// The chat's error lines, under the thread or over the expanded panel
/// (#786) — wherever the owner is looking.
struct ChatErrorStrip: View {
    let chatVM: ChatViewModel

    var body: some View {
        // Nothing at all without an error, so a caller's padding adds no gap.
        if chatVM.errorMessage != nil || chatVM.liveTurn?.persistError != nil || chatVM.actionFeed.lastError != nil {
            VStack(alignment: .leading, spacing: 6) {
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
        }
    }
}
