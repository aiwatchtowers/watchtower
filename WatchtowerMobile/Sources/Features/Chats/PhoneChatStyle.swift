import ChatUI
import SwiftUI

/// The phone's look for the shared chat views (unified chat spec §14, D18): `ChatUI` draws its buttons, cards and
/// chips through this, from the phone's DesignSystem (`Card`, `ChatCardButtonStyle`, the chip on `Fill.card`).
/// Injected once on the conversation screen and its sheets (`ChatConversationView.style`).
struct PhoneChatStyle: ChatUIStyle {
    func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(ChatCardButtonStyle(fill: PhoneTone.accent.color, label: .white)))
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(ChatCardButtonStyle(fill: Fill.card, label: .primary)))
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView {
        AnyView(content().card())
    }

    func chip(_ title: String) -> AnyView {
        AnyView(
            Text(title)
                .font(TypeScale.pill)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.small)
                .background(Fill.card, in: Capsule())
        )
    }

    /// A file waiting in the composer (mockup 2b's pill): its upload in flight, Retry on a refused upload, remove.
    func attachmentChip(_ chip: ChatAttachmentChipContent) -> AnyView {
        AnyView(
            HStack(spacing: Spacing.small) {
                if !chip.icon.isEmpty { Image(systemName: chip.icon) }
                Text(chip.name).lineLimit(1)
                switch chip.state {
                case .importing: ProgressView().controlSize(.mini)
                case .failed: if let retry = chip.onRetry { Button(ChatsGateModel.retry, action: retry) }
                case .attached: EmptyView()
                }
                if let remove = chip.onRemove {
                    Button(action: remove) { Image(systemName: "xmark") }
                        .disabled(chip.removeDisabled)
                        .accessibilityLabel(ChatConversationView.removeFileLabel)
                }
            }
            .font(TypeScale.pill)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(Fill.card, in: Capsule())
        )
    }
}

extension ChatHostText {
    /// The phone names the tower in the shared chat's lines (#1783): its name, "your tower" without one.
    static func phone(_ hubName: String) -> ChatHostText { ChatHostText(hostName: TowerText.name(hubName)) }
}

/// A compact button inside a chat card (an approval's Approve and Reject, a question's Send): the row radius, a
/// filled background and a label colour, dimmed while pressed and when off.
struct ChatCardButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color

    func makeBody(configuration: Configuration) -> some View {
        ChatCardButtonLabel(configuration: configuration, fill: fill, label: label)
    }
}

private struct ChatCardButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let label: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(TypeScale.rowEmphasis)
            .foregroundStyle(isEnabled ? label : Color.secondary)
            .padding(.horizontal, Spacing.medium)
            .frame(minHeight: PhoneMetrics.minTouch - Spacing.regular)
            .background(isEnabled ? fill : Fill.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .opacity(configuration.isPressed ? PhoneOpacity.pressed : 1)
    }
}
