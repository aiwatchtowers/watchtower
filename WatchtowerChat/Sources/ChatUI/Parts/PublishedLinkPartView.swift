import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// "Published on claude.ai" (the `published_link` part). CHAT-05: only a claude.ai page (`PublishedLink.permits`) gets
/// the card, and it only opens or copies the link; any other URL renders the part's fallback text.
struct PublishedLinkPartView: View {
    static let title = "Published on claude.ai"
    static let openLabel = "Open in Browser"
    static let copyLabel = "Copy Link"

    let payload: ChatPublishedLinkPayload
    let url: URL
    let context: ChatPartContext
    @Environment(\.chatUIStyle) private var style

    init?(payload: ChatPublishedLinkPayload, context: ChatPartContext) {
        guard let url = URL(string: payload.url), PublishedLink.permits(url) else { return nil }
        self.payload = payload
        self.url = url
        self.context = context
    }

    var body: some View {
        style.card {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label(Self.title, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                Text(payload.title.isEmpty ? url.absoluteString : payload.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: Spacing.regular) {
                    style.secondaryButton(Self.openLabel) { context.actions.openURL(url) }
                    style.secondaryButton(Self.copyLabel) { context.actions.copy(url.absoluteString) }
                }
            }
        }
        .accessibilityLabel("\(Self.title): \(payload.title)")
        .accessibilityIdentifier("chat.publishedLink")
    }
}
