import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// How the chat draws its controls (unified chat spec §14, D18). The tokens come from `WatchtowerDesign`; the
/// controls themselves live in each app's own kit (the Mac's DesignKit, the phone's DesignSystem), which this package
/// cannot import, so the app injects a style: `.environment(\.chatUIStyle, DesignKitChatStyle())` on the Mac,
/// `PhoneChatStyle()` on the phone. The default is plain and is meant for tests and previews.
public protocol ChatUIStyle {
    func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView
    func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView
    func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView
    func chip(_ title: String) -> AnyView
    /// A question card's "Other…" field: `onSubmit` (⌘↩) sends the card, nil while it is incomplete. The default is a
    /// growing text field; the Mac draws its multi-line comment editor.
    func questionOtherField(text: Binding<String>, placeholder: String, onSubmit: (() -> Void)?) -> AnyView
    /// The owner's bubble around its content.
    func ownerBubble(_ content: AnyView) -> AnyView
    /// A row's Copy.
    func copyButton(_ action: @escaping () -> Void) -> AnyView
    /// A row's actions show only while the pointer is over it (and on the last row).
    var actionsOnHover: Bool { get }
    /// The gap between a message and its actions row.
    var rowSpacing: CGFloat { get }
    /// The gap between a row's actions.
    var actionsSpacing: CGFloat { get }
    /// A question card's frame.
    func questionCard(_ content: AnyView) -> AnyView
    /// A question option's "Recommended" mark.
    func recommendedMark(_ title: String) -> AnyView
    /// A failed or cut reply's card drawn by the app; nil draws ChatUI's own.
    func errorCard(_ content: ChatErrorCardContent) -> AnyView?
    /// A reply's actions row shows only once it is complete (not on a failed or cut one).
    var actionsOnCompleteRepliesOnly: Bool { get }
    /// A reply's tool steps come before its text (the Mac's embedded chats); off, they follow it (Go's part order).
    var stepsFirst: Bool { get }
    /// One tool step's line drawn by the app (the Mac's embedded chats name the call from its arguments); nil draws
    /// ChatUI's own line.
    func stepLine(_ step: ChatStepLine, turnRunning: Bool) -> AnyView?
    /// A chat list row drawn by the app (the Mac's Chats panel keeps the row it had, spec §2 "a move, not a
    /// redesign"); nil draws ChatUI's own row.
    func listRow(_ content: ChatListRowContent) -> AnyView?

    // MARK: The composer (#1822 T13). The defaults draw the phone's look; the Mac's DesignKitChatStyle its own.

    /// The frame around the composer's text view (its padding and background).
    func composerFieldBackground(_ field: AnyView) -> AnyView
    /// The composer's Send, or Stop while a turn runs; off when `active` is false.
    func sendStopButton(isStreaming: Bool, active: Bool, action: @escaping () -> Void) -> AnyView
    /// One attachment chip of the draft.
    func attachmentChip(_ chip: ChatAttachmentChipContent) -> AnyView
    /// A picked mention or skill, with its remove.
    func composerChip(_ chip: ChatComposerChipContent) -> AnyView
    /// One quote of the pending batch: the quote, its editable comment, and its remove.
    func quoteRow(_ quote: ChatQuoteDraft, comment: Binding<String>, onRemove: @escaping () -> Void) -> AnyView
    /// The `@`/`/` picker's rows, the selected one marked.
    func pickerList(_ rows: [ComposerPickerItem], selected: Int, onPick: @escaping (Int) -> Void) -> AnyView

    // MARK: The approval card (unified chat T15)

    /// An approval card's frame; `outlined` marks the card the running turn waits on. The default is the phone's card.
    func approvalCard(_ content: AnyView, outlined: Bool) -> AnyView
    /// An approval card's header line: the tool's title and the status.
    func approvalHeader(_ header: ChatApprovalHeader) -> AnyView
    /// A decision button (Approve, Reject); `prominent` for the one that approves.
    func approvalButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> AnyView
    /// A Slack proposal's message text, shown read-only.
    func approvalSlackText(_ text: String) -> AnyView
}

/// What an approval card's header shows (`ChatUIStyle.approvalHeader`).
public struct ChatApprovalHeader {
    public let title: String
    public let status: String
    /// The proposal writes outside Watchtower (Jira, Slack…): the Mac's external icon.
    public let external: Bool
    /// Waiting for the owner (orange on the phone), done, failed, or neither.
    public let kind: Kind

    public enum Kind: Equatable, Sendable { case waiting, done, failed, neutral }
}

/// One tool step as `ChatUIStyle.stepLine` gets it. `argsJSON` and `isWaiting` are set only by a client that has them.
public struct ChatStepLine {
    public let name: String
    public let outcome: ChatFeed.Step.Outcome
    public let summary: String
    public let argsJSON: String?
    public let isWaiting: Bool

    public init(name: String, outcome: ChatFeed.Step.Outcome, summary: String, argsJSON: String?, isWaiting: Bool) {
        self.name = name
        self.outcome = outcome
        self.summary = summary
        self.argsJSON = argsJSON
        self.isWaiting = isWaiting
    }
}

/// What a failed or cut reply's card says and offers (`ChatUIStyle.errorCard`); a nil action is not offered.
public struct ChatErrorCardContent {
    public let code: String?
    public let message: String
    public let detail: String?
    public let retry: (() -> Void)?
    public let continueStopped: (() -> Void)?
    public let reviewActions: (() -> Void)?
    /// The reply has text before the card.
    public let replyHasText: Bool
}

extension ChatUIStyle {
    public func questionOtherField(text: Binding<String>, placeholder: String, onSubmit: (() -> Void)?) -> AnyView {
        AnyView(
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...4)
                .font(.callout)
        )
    }

    public func ownerBubble(_ content: AnyView) -> AnyView {
        AnyView(
            content
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
                .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.bubble))
        )
    }

    public func copyButton(_ action: @escaping () -> Void) -> AnyView {
        secondaryButton(ChatMessageRow.copyLabel, action: action)
    }

    public var actionsOnHover: Bool { false }
    public var rowSpacing: CGFloat { Spacing.regular }
    public var actionsSpacing: CGFloat { Spacing.regular }

    public func questionCard(_ content: AnyView) -> AnyView { card { content } }

    public func recommendedMark(_ title: String) -> AnyView { chip(title) }

    public func errorCard(_ content: ChatErrorCardContent) -> AnyView? { nil }

    public var actionsOnCompleteRepliesOnly: Bool { false }

    public var stepsFirst: Bool { false }

    public func stepLine(_ step: ChatStepLine, turnRunning: Bool) -> AnyView? { nil }

    public func listRow(_ content: ChatListRowContent) -> AnyView? { nil }

    public func composerFieldBackground(_ field: AnyView) -> AnyView {
        AnyView(
            field
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
                .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.bubble))
        )
    }

    public func sendStopButton(isStreaming: Bool, active: Bool, action: @escaping () -> Void) -> AnyView {
        if isStreaming {
            return AnyView(secondaryButton(ChatComposerModel.stopLabel, action: action)
                .disabled(!active)
                .accessibilityIdentifier("chat.composer.stop"))
        }
        return AnyView(primaryButton(ChatComposerModel.sendLabel, action: action)
            .disabled(!active)
            .accessibilityIdentifier("chat.composer.send"))
    }

    public func attachmentChip(_ chip: ChatAttachmentChipContent) -> AnyView {
        AnyView(
            HStack(spacing: Spacing.small) {
                if !chip.icon.isEmpty { Image(systemName: chip.icon) }
                Text(chip.name).lineLimit(1).truncationMode(.middle)
                switch chip.state {
                case .importing: ProgressView().controlSize(.mini)
                case .failed: if let retry = chip.onRetry { Button(ChatComposerModel.retryLabel, action: retry) }
                case .attached: EmptyView()
                }
                if let remove = chip.onRemove {
                    Button(action: remove) { Image(systemName: "xmark") }
                        .disabled(chip.removeDisabled)
                        .accessibilityLabel("Remove \(chip.name)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(Fill.card, in: Capsule())
        )
    }

    public func composerChip(_ chip: ChatComposerChipContent) -> AnyView {
        AnyView(
            HStack(spacing: Spacing.tight) {
                self.chip(chip.title)
                Button(action: chip.onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(chip.title)")
            }
        )
    }

    public func quoteRow(_ quote: ChatQuoteDraft, comment: Binding<String>, onRemove: @escaping () -> Void) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: Spacing.regular) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("\u{201C}\(quote.quote)\u{201D}")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    TextField("Comment (optional)", text: comment, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.callout)
                }
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove quote")
            }
            .padding(Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row))
        )
    }

    public func pickerList(_ rows: [ComposerPickerItem], selected: Int, onPick: @escaping (Int) -> Void) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button { onPick(index) } label: {
                        HStack(spacing: Spacing.regular) {
                            Image(systemName: row.icon).foregroundStyle(.secondary).frame(width: IconSize.composer)
                            Text(row.title).lineLimit(1)
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.regular)
                        .padding(.vertical, Spacing.small)
                        .background(index == selected ? Fill.selected : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Radius.row))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(Spacing.small)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row))
        )
    }

    public func approvalCard(_ content: AnyView, outlined: Bool) -> AnyView {
        AnyView(card { content }.overlay {
            if outlined {
                RoundedRectangle(cornerRadius: Radius.container).strokeBorder(Tone.warning, lineWidth: Stroke.selection)
            }
        })
    }

    public func approvalHeader(_ header: ChatApprovalHeader) -> AnyView {
        let tone: Color = switch header.kind {
        case .waiting: Tone.warning
        case .done: Tone.success
        case .failed: Tone.error
        case .neutral: .secondary
        }
        return AnyView(HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(header.title).font(.callout.weight(.semibold)).lineLimit(2)
            Spacer(minLength: Spacing.regular)
            Text(header.status)
                .font(.caption)
                .foregroundStyle(tone)
                .accessibilityIdentifier("agentAction.status")
        })
    }

    public func approvalButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> AnyView {
        prominent ? primaryButton(title, action: action) : secondaryButton(title, action: action)
    }

    public func approvalSlackText(_ text: String) -> AnyView {
        AnyView(
            Text(text)
                .font(.callout)
                .padding(Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                .textSelection(.enabled)
        )
    }
}

/// The default style: borderless controls on the shared tokens, no app look.
public struct PlainChatUIStyle: ChatUIStyle {
    public init() {}

    public func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(.borderless).fontWeight(.semibold))
    }

    public func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(.borderless))
    }

    public func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView {
        AnyView(
            content()
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
        )
    }

    public func chip(_ title: String) -> AnyView {
        AnyView(
            Text(title)
                .font(.caption)
                .padding(.horizontal, Spacing.compact)
                .padding(.vertical, Spacing.tight)
                .background(Fill.rest, in: Capsule())
        )
    }
}

private struct ChatUIStyleKey: EnvironmentKey {
    static let defaultValue: any ChatUIStyle = PlainChatUIStyle()
}

extension EnvironmentValues {
    /// The style the chat draws its buttons, cards and chips with; plain unless the app injects its own.
    public var chatUIStyle: any ChatUIStyle {
        get { self[ChatUIStyleKey.self] }
        set { self[ChatUIStyleKey.self] = newValue }
    }
}
