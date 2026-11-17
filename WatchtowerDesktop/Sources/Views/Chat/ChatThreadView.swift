import AppKit
import ChatUI
import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// The centered thread column (spec §3.1, max ~760 pt) on ChatUI's shared feed: the engine's messages, each part
/// drawn by its registered view, with the Mac's own pieces injected — the agent-action card shared with the Inbox
/// (approvals stay on `actions approve|reject`, D12), the inspector for artifacts and sources, and link handling.
struct ChatThreadView: View {
    @Bindable var chatVM: ChatViewModel
    @Environment(AppState.self) private var appState
    let ownerName: String

    var body: some View {
        VStack(spacing: 0) {
            if chatVM.messages.isEmpty, chatVM.conversation.feed != nil {
                ChatEmptyState(ownerName: ownerName, onPrompt: usePrompt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatUI.ChatFeedView(messages: chatVM.messages, context: feedContext)
            }
            ChatErrorStrip(chatVM: chatVM)
                .padding(.horizontal, Spacing.cozy)
        }
        .task(id: chatVM.conversationID) { await chatVM.loadArtifactContext() }
        .task(id: chatVM.messages.last?.id) { await chatVM.conversation.markRead() }
        .task(id: chatVM.messages.first?.id) { await chatVM.conversation.followFocus() }
        .onChange(of: chatVM.conversation.messages, initial: true) { _, _ in chatVM.feedChanged() }
        .onChange(of: chatVM.actionFeed.rows) { _, _ in chatVM.feedChanged() }
    }

    private var feedContext: ChatFeedContext {
        var context = chatVM.conversation.feedContext(composer: chatVM.composer, partActions: partActions)
        context.rowActions.quote = { chatVM.addQuote($0) }
        context.notice = chatVM.conversation.notice
        context.messageAccessory = { message in messageAccessory(message) }
        context.footer = unattachedCards
        return context
    }

    /// Under a reply: "Approve all" when its turn has two or more cards to approve, and the reviewed actions.
    private func messageAccessory(_ message: ChatFeed.Message) -> AnyView? {
        let turn = chatVM.turnID(ofApprovalsIn: message)
        let bulk = turn.map { chatVM.actionFeed.bulkApprovable(forTurn: $0) } ?? []
        let reviewed = chatVM.reviewedMessageID == message.id
        guard bulk.count >= 2 || reviewed else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
            if bulk.count >= 2, let turn {
                Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                    .font(.caption)
            }
            if reviewed {
                ChatActionReviewView(actions: chatVM.actionFeed.rows.filter { chatVM.reviewedActionIDs.contains($0.id) })
            }
        })
    }

    /// Proposals of a turn that stored no message (it was interrupted): reachable only here.
    private var unattachedCards: AnyView? {
        let orphans = chatVM.unattachedActions
        guard !orphans.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Proposals from an interrupted turn").font(.caption).foregroundStyle(.secondary)
            ForEach(orphans) { action in agentActionCard(action) }
        })
    }

    private var partActions: ChatPartActions {
        ChatPartActions(
            openURL: open,
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            openArtifact: { chatVM.openArtifact(key: $0.key) },
            openSources: { sources in
                let replyID = chatVM.messages.last { $0.role == "assistant" }?.id ?? 0
                chatVM.openSources(messageID: replyID, sources: sources)
            },
            decide: { payload, decision in
                let feed = chatVM.actionFeed
                switch decision {
                case .approve:
                    // The row's stored args when it is loaded, else the digest the part carries. A part without
                    // one pins the digest of nothing, which Go refuses as changed args, shown on the row (AGENT-07).
                    let shown = feed.rows.first { $0.id == payload.id } ?? ChatAgentAction(payload: payload)
                    let digest = shown.approveDigest ?? ChatAgentAction.digest(of: "")
                    Task { await feed.approve(payload.id, digest: digest) }
                case .reject:
                    Task { await feed.reject(payload.id) }
                }
            },
            approvalCard: { payload in
                guard let action = chatVM.actionFeed.rows.first(where: { $0.id == payload.id }) else { return nil }
                return AnyView(agentActionCard(action))
            },
            reviewActions: { id in Task { await chatVM.reviewActions(messageID: id) } }
        )
    }

    /// A link in an answer: an in-app screen, else the system's handler for the schemes the chat allows.
    private func open(_ url: URL) {
        if url.scheme?.lowercased() == NavLink.scheme {
            appState.openNavLink(url)
        } else if AllowedURLSchemes.permits(url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func usePrompt(_ prompt: ChatStarterPrompt) {
        chatVM.composer.draft = prompt.text
        if prompt.sendsImmediately { Task { await chatVM.sendDraft() } }
    }

    /// The Mac's own card (Slack editing and workspace pick, reconnect, the automation editor), shared with the
    /// Inbox; a card the running turn waits on (or one under review) is outlined.
    private func agentActionCard(_ action: AgentAction) -> some View {
        let feed = chatVM.actionFeed
        let awaited = chatVM.isAwaited(action)
        return AgentActionCardView(
            action: action,
            inFlight: feed.inFlight.contains(action.id),
            onApprove: { Task { await feed.approve(action.id, shownArgs: action.argsJSON) } },
            onReject: { Task { await feed.reject(action.id) } },
            onRetry: { Task { await feed.retry(action.id) } },
            gestureError: feed.rowErrors[action.id],
            onApproveEdited: { patch in Task { await feed.approve(action.id, shownArgs: action.argsJSON, patch: patch) } },
            onReconnectSlack: { id in await appState.reconnectSlack(accountID: id) },
            onDismiss: { Task { await feed.dismiss(action.id) } },
            sessionHoldsCall: chatVM.holdsSessionCall(action)
        )
        .overlay {
            if awaited {
                RoundedRectangle(cornerRadius: Radius.container).strokeBorder(Tone.warning, lineWidth: Stroke.selection)
            }
        }
    }
}

/// The chat's error lines, under the thread or over the expanded panel (#786) — wherever the owner is looking.
struct ChatErrorStrip: View {
    let chatVM: ChatViewModel

    var body: some View {
        // Nothing at all without an error, so a caller's padding adds no gap.
        if chatVM.errorMessage != nil || chatVM.actionFeed.lastError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let error = chatVM.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Tone.error)
                        .padding(Spacing.regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tone.error.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.control))
                }
                if let err = chatVM.actionFeed.lastError {
                    Text(err).font(.caption).foregroundStyle(Tone.error)
                }
            }
        }
    }
}
