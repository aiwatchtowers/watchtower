import ChatWire
import SwiftUI
import WatchtowerDesign

/// The line above the composer while the chat cannot be reached (unified chat spec D11, §6.2): what is wrong and,
/// when the owner can do something, the one button. The copy is pinned here and by `ChatUITests`.
public enum ChatStateLine {
    public struct Content: Equatable, Sendable {
        public let text: String
        /// The button's title; nil when there is nothing to press.
        public let action: String?

        public init(text: String, action: String? = nil) {
            self.text = text
            self.action = action
        }
    }

    public static let starting = "Chat is starting…"
    public static let unavailable = "Chat is unavailable — Watchtower's background service is not running"
    public static let stopped = "Chat needs Watchtower's background service, which is stopped"
    public static let retry = "Retry"
    public static let start = "Start"

    /// Nil while connected. `.offline` carries the transport's own sentence (the phone's relay line).
    public static func content(for reachability: ChatReachability) -> Content? {
        switch reachability {
        case .connected: nil
        case .starting: Content(text: starting)
        case .unavailable: Content(text: unavailable, action: retry)
        case .stoppedOnPurpose: Content(text: stopped, action: start)
        case .offline(let reason): reason.isEmpty ? nil : Content(text: reason)
        }
    }
}

/// The state line itself: a secondary sentence and, when there is one, its button.
public struct ChatStateLineView: View {
    let content: ChatStateLine.Content
    let onAction: () -> Void
    @Environment(\.chatUIStyle) private var style

    public init(content: ChatStateLine.Content, onAction: @escaping () -> Void) {
        self.content = content
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(content.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = content.action {
                style.secondaryButton(action, action: onAction)
                    .accessibilityIdentifier("chat.stateLine.action")
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.compact)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.stateLine")
    }
}
