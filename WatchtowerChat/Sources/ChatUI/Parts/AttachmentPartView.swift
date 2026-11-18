import ChatWire
import SwiftUI
import WatchtowerDesign

/// A file the owner attached to the message (the `attachment` part).
struct AttachmentPartView: View {
    let attachment: ChatFeed.Attachment
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: Self.icon(attachment.mime)).foregroundStyle(.secondary)
            Text(attachment.name).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.small)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityIdentifier("chat.attachment")
    }

    static func icon(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc.text"
    }
}
