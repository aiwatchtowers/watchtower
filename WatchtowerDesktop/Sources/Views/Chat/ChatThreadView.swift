import AppKit
import ChatUI
import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// The centered thread column (spec §3.1, max ~760 pt) on ChatUI's shared feed: the engine's messages, each part
/// drawn by its registered view, with the Mac's own pieces injected — the approval card's services on the
/// conversation's action feed (approvals stay on `actions approve|reject`, D12), the inspector for artifacts and
/// sources, and link handling.
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

    /// Under a reply: the actions under review ("Review actions" on a reply stopped by the quota). **Approve all** is
    /// ChatUI's own (`ChatApprovalServices.approveAll`).
    private func messageAccessory(_ message: ChatFeed.Message) -> AnyView? {
        guard chatVM.reviewedMessageID == message.id else { return nil }
        return AnyView(ChatActionReviewView(actions: chatVM.actionFeed.rows.filter { chatVM.reviewedActionIDs.contains($0.id) }))
    }

    /// Proposals of a turn that stored no message (it was interrupted): reachable only here.
    private var unattachedCards: AnyView? {
        let orphans = chatVM.unattachedActions
        guard !orphans.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Proposals from an interrupted turn").font(.caption).foregroundStyle(.secondary)
            ForEach(orphans) { action in
                ChatUI.AgentActionCard(action: action, services: approvals, outlined: chatVM.isAwaited(action))
            }
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
            reviewActions: { id in Task { await chatVM.reviewActions(messageID: id) } },
            approvals: approvals
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

    /// The approval cards' services: the conversation's action feed (the CLI with owner-confirm), Reconnect Slack, and
    /// the session calls this chat's running turn holds; a card under review is marked like an awaited one.
    var approvals: ChatApprovalServices {
        let chatVM = chatVM
        return .mac(feed: chatVM.actionFeed, highlighted: { chatVM.reviewedActionIDs.contains($0.id) },
                    reconnectSlack: { id in await appState.reconnectSlack(accountID: id) },
                    cancelReconnectSlack: { appState.cancelCardSlackSignIn(accountID: $0) },
                    sessionHolds: chatVM.holdsSessionCall)
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
