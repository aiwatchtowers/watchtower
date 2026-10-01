import SwiftUI
import WatchtowerCore

// MARK: - Chat Section (tab bar + active chat)

/// The target's assistant surface: a chip row of chat tabs on top, the active
/// tab's conversation below. The container owns the chat VMs, so switching tabs
/// never interrupts a turn running in the tab you left.
struct TargetChatSection: View {
    @Bindable var assistant: TargetAssistantViewModel

    @State private var renamingConversationID: Int64?
    @State private var renameText: String = ""
    @State private var showRename = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            if let chatVM = assistant.activeChat {
                TargetChatPane(chatVM: chatVM)
            } else {
                noChatState
            }
        }
        .alert("Rename chat", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renamingConversationID {
                    assistant.rename(id, to: renameText)
                }
            }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(assistant.conversations) { conversation in
                        chip(conversation)
                    }
                }
                .padding(.vertical, 1)
            }
            Button {
                assistant.newConversation()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Start another chat on this task")
            .accessibilityIdentifier("chat.newTab")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func chip(_ conversation: ChatConversation) -> some View {
        let isActive = conversation.id == assistant.activeConversationID
        return Button {
            assistant.select(conversation.id)
        } label: {
            HStack(spacing: 5) {
                if assistant.isWorking(conversation.id) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .help("This chat is working")
                }
                Text(conversation.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: 180)
            .background(
                isActive ? Color.accentColor.opacity(0.18) : Color(.controlBackgroundColor),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.accentColor.opacity(0.35) : Color(.separatorColor).opacity(0.4),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.tab.\(conversation.id)")
        .contextMenu {
            Button("Rename…") {
                renamingConversationID = conversation.id
                renameText = conversation.title
                showRename = true
            }
            Button("Close", role: .destructive) {
                assistant.close(conversation.id)
            }
            .disabled(assistant.conversations.count <= 1)
        }
    }

    private var noChatState: some View {
        VStack(spacing: 6) {
            Text(assistant.errorMessage ?? "No chat is open for this task.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start a chat") { assistant.newConversation() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - One chat

/// One conversation on the shared embedded chat component: the feed and
/// composer of the AI Chat, with the target's proposals in the accessory slot
/// under each reply (its `watchtower-action` cards, batched with Approve all
/// from `batchCollapseThreshold` on, then the registry proposals of that turn)
/// and the proposals of an interrupted turn in the footer.
struct TargetChatPane: View {
    let chatVM: TargetChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            EmbeddedChatView(
                engine: chatVM.engine,
                placeholder: "Ask the assistant to work on this task…",
                dictationTargetID: "chat.target.\(chatVM.targetID)",
                accessory: { item in TargetChatProposals(chatVM: chatVM, item: item) },
                footer: { footer }
            )
        }
        // The composer is the pane's bottom-most content.
        .clearsRecordingIndicator()
        .background(Color(.controlBackgroundColor).opacity(0.4))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Footer

    /// Below the feed: proposals whose turn never persisted a message (a
    /// stream that died mid-turn — without a slot of their own they would be
    /// unreachable), the feed's last gesture error and a deleted task.
    @ViewBuilder
    private var footer: some View {
        let orphans = AgentActionFeed.unattached(
            rows: chatVM.actionFeed.rows,
            messageTurnIDs: Set(chatVM.engine.messages.map(\.message.turnID).filter { !$0.isEmpty })
        )
        if !orphans.isEmpty || chatVM.actionFeed.lastError != nil || chatVM.targetGone {
            VStack(alignment: .leading, spacing: 6) {
                if !orphans.isEmpty {
                    Text("Proposals from an interrupted turn")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Bounded: a long list must not squeeze the feed out.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(orphans) { action in agentActionCard(action) }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                if let err = chatVM.actionFeed.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if chatVM.targetGone {
                    Label("This task no longer exists — it may have been deleted.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func agentActionCard(_ action: AgentAction) -> some View {
        AgentActionCardView(
            action: action,
            inFlight: chatVM.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chatVM.actionFeed.approve(action.id) } },
            onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
            onRetry: { Task { await chatVM.actionFeed.retry(action.id) } },
            gestureError: chatVM.actionFeed.rowErrors[action.id]
        )
    }
}

/// What sits under one reply of the target chat: its `watchtower-action`
/// cards (batched with Approve all from `batchCollapseThreshold` on), then
/// the registry proposals of that turn with their own Approve all.
struct TargetChatProposals: View {
    let chatVM: TargetChatViewModel
    let item: ChatThreadItem

    /// From this many cards on, a turn's proposals render as one collapsed
    /// block instead of a screenful of individual cards.
    private static let batchCollapseThreshold = 4

    /// Whether the user expanded this reply's batch block to review one by one.
    @State private var expandedBatches: Set<UUID> = []

    var body: some View {
        let messageID = UUID(chatRowID: item.id)
        let cards = chatVM.actionCards.filter { $0.messageID == messageID }
        if cards.count >= Self.batchCollapseThreshold {
            collapsedBatch(for: messageID, cards: cards)
        } else if !cards.isEmpty {
            batchApproveRow(for: messageID, cards: cards)
            ForEach(cards) { card in actionCardView(card) }
        }
        // Registry proposals sit under the reply only — the owner's row of
        // the same turn carries the same turn id.
        if item.message.isAssistant, !item.message.turnID.isEmpty {
            agentActionCards(forTurn: item.message.turnID)
        }
    }

    private func actionCardView(_ card: TargetActionCard) -> some View {
        TargetActionCardView(
            card: card,
            currentTargetID: chatVM.targetID,
            onApprove: { kind in chatVM.approve(card, as: kind) },
            onReject: { chatVM.reject(card) }
        )
    }

    /// A big batch as one compact block: what it is (count + composition), one
    /// Approve all button, and a Review toggle that expands to the per-card
    /// list for deciding individually. Card states keep updating the block's
    /// summary line after decisions land.
    @ViewBuilder
    private func collapsedBatch(for messageID: UUID, cards: [TargetActionCard]) -> some View {
        let pending = cards.filter { $0.state == .pending }.count
        let expanded = expandedBatches.contains(messageID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cards.count) proposed changes")
                        .font(.subheadline.weight(.medium))
                    Text(cards.batchBreakdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let states = cards.batchStateSummary {
                        Text(states)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if pending > 0 {
                    Button { chatVM.approveAll(messageID: messageID) } label: {
                        Label("Approve all", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Apply every pending proposal in this batch and tell the assistant once")
                    .accessibilityIdentifier("chat.approveAll")
                }
                Button {
                    if expanded {
                        expandedBatches.remove(messageID)
                    } else {
                        expandedBatches.insert(messageID)
                    }
                } label: {
                    Label(expanded ? "Collapse" : "Review",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(expanded ? "Hide the individual proposals"
                               : "Review and decide each proposal individually")
                .accessibilityIdentifier("chat.batchReview")
            }
            if expanded {
                ForEach(cards) { card in actionCardView(card) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    /// Rendered in the transcript itself, directly above a message's batch of
    /// proposal cards — the affordance sits where the cards are, not in a
    /// header or a docked bar the eye never visits.
    @ViewBuilder
    private func batchApproveRow(for messageID: UUID, cards: [TargetActionCard]) -> some View {
        let pending = cards.filter { $0.state == .pending }.count
        if pending > 1 {
            HStack(spacing: 8) {
                Text("\(pending) proposals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { chatVM.approveAll(messageID: messageID) } label: {
                    Label("Approve all", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Apply every pending proposal in this batch and tell the assistant once")
                .accessibilityIdentifier("chat.approveAll")
                Spacer()
            }
        }
    }

    // MARK: Registry proposals

    /// Agent-tool proposal cards attached to one turn — the same
    /// `AgentActionFeed` contract as the main chat, added after the
    /// `TargetActionCardView` cards for the message so both proposal kinds
    /// interleave in turn order rather than one hiding behind the other.
    @ViewBuilder
    private func agentActionCards(forTurn turn: String) -> some View {
        let cards = chatVM.actionFeed.cards(forTurn: turn)
        if cards.filter(\.isPending).count >= 2 {
            Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                .font(.caption)
        }
        ForEach(cards) { action in
            agentActionCard(action)
        }
    }

    private func agentActionCard(_ action: AgentAction) -> some View {
        AgentActionCardView(
            action: action,
            inFlight: chatVM.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chatVM.actionFeed.approve(action.id) } },
            onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
            onRetry: { Task { await chatVM.actionFeed.retry(action.id) } },
            gestureError: chatVM.actionFeed.rowErrors[action.id]
        )
    }
}

// MARK: - Action Card

struct TargetActionCardView: View {
    let card: TargetActionCard
    /// The chat's own target — an action addressing any OTHER task (target_id)
    /// gets an explicit "→ in task #N" line so the user sees where it will land.
    let currentTargetID: Int
    /// `kind` is the user's chosen create-kind for checkpoint/sub-task proposals (nil otherwise).
    let onApprove: (TargetActionKind?) -> Void
    let onReject: () -> Void

    /// For add_sub_item / create_child_target the user picks what to actually create.
    @State private var createKind: TargetActionKind

    init(
        card: TargetActionCard,
        currentTargetID: Int,
        onApprove: @escaping (TargetActionKind?) -> Void,
        onReject: @escaping () -> Void
    ) {
        self.card = card
        self.currentTargetID = currentTargetID
        self.onApprove = onApprove
        self.onReject = onReject
        _createKind = State(initialValue: card.action.type)
    }

    /// The addressed task when it is not this chat's own target (link_target's
    /// target_id is the link endpoint, not an address).
    var addressedTargetID: Int? {
        guard card.action.type != .linkTarget,
              let id = card.action.targetId, id != currentTargetID else { return nil }
        return id
    }

    /// add_sub_item and create_child_target are interchangeable — both just need
    /// `text`, so the user can pick either at approve time.
    private var isCreatable: Bool {
        card.action.type == .addSubItem || card.action.type == .createChildTarget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text("Proposed change")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let addressed = addressedTargetID {
                Label("in task #\(addressed)", systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.card.addressedTarget")
            }

            Text(card.action.cardDescription)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            switch card.state {
            case .pending:
                if isCreatable {
                    Picker("Create as", selection: $createKind) {
                        Text("Checkpoint").tag(TargetActionKind.addSubItem)
                        Text("Sub-task").tag(TargetActionKind.createChildTarget)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Button { onApprove(isCreatable ? createKind : nil) } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(action: onReject) {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .applied(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .rejected:
                Label("Rejected", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let err):
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var icon: String {
        switch card.action.type {
        case .updateStatus: "flag.fill"
        case .updateNotes: "note.text"
        case .updateProgress: "chart.bar.fill"
        case .addSubItem: "checklist"
        case .createChildTarget: "plus.square.on.square"
        case .linkTarget: "link"
        case .toggleSubItem: "checkmark.circle"
        case .editSubItem: "pencil"
        case .deleteSubItem: "trash"
        case .setSubItemDue: "calendar.badge.clock"
        case .updateDueDate: "calendar"
        case .updatePriority: "exclamationmark.circle"
        case .updateBallOn: "person.circle"
        case .updateTitle: "pencil.line"
        case .updateIntent: "text.alignleft"
        case .addLabel: "tag"
        case .removeLabel: "tag.slash"
        }
    }
}
