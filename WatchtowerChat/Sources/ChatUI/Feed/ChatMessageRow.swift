import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// One message: the owner's as a bubble on the right, a reply as its parts in reading order, with the row's actions
/// (copy, regenerate, edit, the branch switcher) under it.
public struct ChatMessageRow: View {
    static let copyLabel = "Copy"
    static let regenerateLabel = "Regenerate"
    static let editLabel = "Edit"
    /// The role of a line that is neither the owner's nor an answer (Workchat's notices, subagent markers and
    /// Watchtower's own lines): `ChatFeedContext.systemRow` draws it.
    public static let systemRole = "system"

    let message: ChatFeed.Message
    let parts: [ChatPart]
    let context: ChatPartContext
    let rowActions: ChatRowActions
    let isTurnRunning: Bool
    let caption: String?
    let captionView: AnyView?
    let ownerHeader: AnyView?
    let isLast: Bool
    @Environment(\.chatUIStyle) private var style
    @State private var hovering = false

    /// `caption` is a line after the actions; `captionView` draws it instead (the Mac's Workchat); `ownerHeader` sits
    /// in the owner's bubble over the text (an ask answer's ask); `isLast` keeps a hover-only actions row visible.
    public init(
        message: ChatFeed.Message,
        parts: [ChatPart],
        context: ChatPartContext,
        rowActions: ChatRowActions,
        isTurnRunning: Bool,
        caption: String? = nil,
        captionView: AnyView? = nil,
        ownerHeader: AnyView? = nil,
        isLast: Bool = false
    ) {
        self.message = message
        self.parts = parts
        self.context = context
        self.rowActions = rowActions
        self.isTurnRunning = isTurnRunning
        self.caption = caption
        self.captionView = captionView
        self.ownerHeader = ownerHeader
        self.isLast = isLast
    }

    private var isOwner: Bool { message.role == "user" }

    public var body: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: style.rowSpacing) {
            if isOwner {
                ownerBubble
            } else {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(Array(replyParts.enumerated()), id: \.offset) { _, part in
                        ChatPartRegistry.view(for: part, context: context)
                    }
                    if message.status == ChatMessageStatus.pending, parts.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            actionsRow
                .opacity(!style.actionsOnHover || hovering || isLast ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("chat.message.\(message.id)")
    }

    /// The reply's parts in drawing order: the steps first where the style asks for it.
    private var replyParts: [ChatPart] {
        guard style.stepsFirst else { return parts }
        return parts.filter { $0.kind == ChatPartKind.steps } + parts.filter { $0.kind != ChatPartKind.steps }
    }

    /// The owner's own words: the stored text's skill and REFERENCED lines (the engine composes them) show as chips.
    private var owner: ChatOwnerTextParts { ChatOwnerText.displayParts(message.text) }

    private var ownerBubble: some View {
        let owner = owner
        let shown = (owner.body.isEmpty ? [] : [ChatMessageParts.textPart(owner.body, cut: false)])
            + parts.filter { $0.kind != ChatPartKind.text }
        let content = VStack(alignment: ownerHeader == nil ? .trailing : .leading, spacing: Spacing.small) {
            if let ownerHeader {
                ownerHeader
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                ChatPartRegistry.view(for: part, context: context)
            }
            if owner.skill != nil || !owner.references.isEmpty {
                HStack(spacing: Spacing.compact) {
                    if let skill = owner.skill { style.chip("/\(skill)") }
                    ForEach(owner.references, id: \.token) { style.chip("@\($0.label)") }
                }
            }
        }
        return style.ownerBubble(AnyView(content))
    }

    @ViewBuilder private var actionsRow: some View {
        if message.status != ChatMessageStatus.pending,
           isOwner || !style.actionsOnCompleteRepliesOnly || message.status == ChatMessageStatus.complete {
            HStack(spacing: style.actionsSpacing) {
                if message.siblings.count > 1 {
                    branchSwitcher
                }
                if rowActions.allowsCopy {
                    style.copyButton { rowActions.copy(isOwner ? owner.body : ChatQuestionParser.readableText(message.text)) }
                }
                if !isOwner, let quote = rowActions.quote {
                    ChatQuoteRowAction(text: message.text, onQuote: quote)
                }
                if !isTurnRunning {
                    if isOwner, rowActions.allowsEdit {
                        style.secondaryButton(Self.editLabel) { rowActions.edit(message) }
                    } else if !isOwner, rowActions.allowsRegenerate {
                        style.secondaryButton(Self.regenerateLabel) { rowActions.regenerate(message.id) }
                    }
                }
                if let captionView {
                    captionView
                } else if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.tertiary)
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
