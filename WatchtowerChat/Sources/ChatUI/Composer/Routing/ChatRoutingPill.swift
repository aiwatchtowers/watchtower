import SwiftUI

/// The routing pill: the provider/model menu of the main chat (R2) and of the code questions (no automatic choice).
/// It draws its label through the style and hands each pick to `onPick`; it writes nothing.
public struct ChatRoutingPill: View {
    let label: String
    let menu: [ChatRoutingMenuSection]
    let enabled: Bool
    let onPick: (ChatRoutingMenuItem) -> Void
    @Environment(\.chatUIStyle) private var style

    public init(label: String, menu: [ChatRoutingMenuSection], enabled: Bool, onPick: @escaping (ChatRoutingMenuItem) -> Void) {
        self.label = label
        self.menu = menu
        self.enabled = enabled
        self.onPick = onPick
    }

    public var body: some View {
        Menu {
            ForEach(menu) { section in
                if let title = section.title {
                    Section(title) { buttons(section) }
                } else {
                    buttons(section)
                }
            }
        } label: {
            style.routingPillLabel(label, enabled: enabled)
        }
        .routingPillMenuStyle()
        .help("Provider and model for this chat")
        .accessibilityIdentifier("chat.composer.model")
        .disabled(!enabled)
    }

    private func buttons(_ section: ChatRoutingMenuSection) -> some View {
        ForEach(section.items) { item in
            Button(item.label) { onPick(item) }
        }
    }
}
