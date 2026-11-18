import ChatWire
import SwiftUI
import WatchtowerDesign

/// What a part this client cannot draw shows (unified chat spec G4): the part's fallback text and one button per
/// fallback action. CHAT-05: a button only sends the fixed owner text of a `chat_turn` the owner presses, opens an
/// http(s) link of an `open_url`, or does nothing (`none`, drawn disabled); an action of any other shape is drawn
/// disabled too.
public struct FallbackPartView: View {
    /// What one fallback button does.
    public enum Effect: Equatable {
        case turn(String)
        case open(URL)
        case none
    }

    public struct Choice: Equatable, Identifiable {
        public let id: Int
        public let label: String
        public let effect: Effect
    }

    let fallback: ChatPartFallback
    let actions: ChatPartActions
    @Environment(\.chatUIStyle) private var style

    public init(fallback: ChatPartFallback, actions: ChatPartActions) {
        self.fallback = fallback
        self.actions = actions
    }

    /// The buttons, one per action, in order.
    public static func buttons(_ fallback: ChatPartFallback) -> [Choice] {
        fallback.actions.enumerated().map { index, action in
            Choice(id: index, label: action.label, effect: effect(action))
        }
    }

    static func effect(_ action: ChatPartFallback.Action) -> Effect {
        switch action.action {
        case "chat_turn":
            guard let text = action.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .none }
            return .turn(text)
        case "open_url":
            guard let raw = action.url, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil
            else { return .none }
            return .open(url)
        default:
            return .none
        }
    }

    public var body: some View {
        style.card {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                if !fallback.text.isEmpty {
                    Text(fallback.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let buttons = Self.buttons(fallback)
                if !buttons.isEmpty {
                    HStack(spacing: Spacing.regular) {
                        ForEach(buttons) { button in
                            style.secondaryButton(button.label) { perform(button.effect) }
                                .disabled(button.effect == .none)
                                .accessibilityIdentifier("chat.fallback.action.\(button.id)")
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("chat.fallback")
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .turn(let text): actions.sendFixedText(text)
        case .open(let url): actions.openURL(url)
        case .none: break
        }
    }
}
