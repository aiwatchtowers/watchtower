import ChatWire
import SwiftUI
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
