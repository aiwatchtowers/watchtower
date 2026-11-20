import ChatUI
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

extension Tone {
    /// A peer card's header: another agent's traffic, a sub-session that finished, a message that waits.
    static func peerBubble(_ tone: PeerBubblePresentation.Tone) -> Color {
        switch tone {
        case .peer: .purple
        case .success: success
        case .waiting: warning
        case .failed: error
        }
    }
}

/// One card of another agent's words in a Workchat feed (spec 2026-11-18 §6.6, mockup `feed-parent-*`): a coloured
/// header line, the body under it, and an optional action on the right. Every string comes from
/// `PeerBubblePresentation`; this only lays it out.
struct PeerBubbleCard: View {
    let bubble: PeerBubblePresentation.Bubble
    /// The parsed body of a message entry; nil draws `bubble.body` as plain text (a reason line, "Brief sent.").
    var blocks: [MarkdownBlock]?
    var onAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(bubble.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tone.peerBubble(bubble.tone))
                if let blocks {
                    MarkdownBlocksView(blocks: blocks).textSelection(.enabled)
                } else if !bubble.body.isEmpty {
                    Text(bubble.body).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = bubble.action, let onAction {
                Button(action, action: onAction).buttonStyle(.link)
            }
        }
        .padding(Spacing.cozy)
        .card()
        .accessibilityElement(children: .combine)
    }
}
