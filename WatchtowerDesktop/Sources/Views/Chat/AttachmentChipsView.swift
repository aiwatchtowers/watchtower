import SwiftUI
import WatchtowerCore

/// A row of pending/sent-attachment chips. `onRemove == nil` renders
/// read-only chips (a sent message's attachments).
struct AttachmentChipsView: View {
    let attachments: [ChatAttachment]
    var onRemove: ((Int64) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: Self.icon(for: attachment.mime))
                        Text(attachment.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let onRemove {
                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(attachment.name)")
                            .help("Remove \(attachment.name)")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    static func icon(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc.text"
    }
}
