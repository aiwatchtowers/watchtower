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
}

extension ChatUIStyle {
    public func questionOtherField(text: Binding<String>, placeholder: String, onSubmit: (() -> Void)?) -> AnyView {
        AnyView(
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...4)
                .font(.callout)
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
