import ChatWire
import SwiftUI
import WatchtowerDesign

/// One message: the owner's as a bubble on the right, a reply as its parts in reading order, with the row's actions
/// (copy, regenerate, edit, the branch switcher) under it.
public struct ChatMessageRow: View {
    static let copyLabel = "Copy"
    static let regenerateLabel = "Regenerate"
    static let editLabel = "Edit"

    let message: ChatFeed.Message
    let parts: [ChatPart]
    let context: ChatPartContext
    let rowActions: ChatRowActions
    let isTurnRunning: Bool
    @Environment(\.chatUIStyle) private var style

    public init(
        message: ChatFeed.Message,
        parts: [ChatPart],
        context: ChatPartContext,
        rowActions: ChatRowActions,
        isTurnRunning: Bool
    ) {
        self.message = message
        self.parts = parts
        self.context = context
        self.rowActions = rowActions
        self.isTurnRunning = isTurnRunning
    }

    private var isOwner: Bool { message.role == "user" }

    public var body: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: Spacing.regular) {
            if isOwner {
                ownerBubble
            } else {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    ChatPartRegistry.view(for: part, context: context)
                }
                if message.status == ChatMessageStatus.pending, parts.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            actionsRow
        }
        .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
        .accessibilityIdentifier("chat.message.\(message.id)")
    }

    private var ownerBubble: some View {
        VStack(alignment: .trailing, spacing: Spacing.small) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                ChatPartRegistry.view(for: part, context: context)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.bubble))
    }

    @ViewBuilder private var actionsRow: some View {
        if message.status != ChatMessageStatus.pending {
            HStack(spacing: Spacing.regular) {
                if message.siblings.count > 1 {
                    branchSwitcher
                }
                style.secondaryButton(Self.copyLabel) { rowActions.copy(message.text) }
                if !isOwner, let quote = rowActions.quote {
                    ChatQuoteRowAction(text: message.text, onQuote: quote)
                }
                if !isTurnRunning {
                    if isOwner {
                        style.secondaryButton(Self.editLabel) { rowActions.edit(message) }
                    } else {
                        style.secondaryButton(Self.regenerateLabel) { rowActions.regenerate(message.id) }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var branchSwitcher: some View {
        HStack(spacing: Spacing.small) {
            Button { message.siblings.neighbour(-1).map(rowActions.selectBranch) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(isTurnRunning || message.siblings.neighbour(-1) == nil)
            .accessibilityLabel("Previous version")
            Text("\(message.siblings.index)/\(message.siblings.count)").monospacedDigit()
            Button { message.siblings.neighbour(1).map(rowActions.selectBranch) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(isTurnRunning || message.siblings.neighbour(1) == nil)
            .accessibilityLabel("Next version")
        }
    }
}
