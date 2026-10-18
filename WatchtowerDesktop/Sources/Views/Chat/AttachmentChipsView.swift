import SwiftUI
import WatchtowerCore

/// A row of pending/sent-attachment chips. `onRemove == nil` renders
/// read-only chips (a sent message's attachments).
struct AttachmentChipsView: View {
    let attachments: [ChatAttachment]
    var onRemove: ((Int64) -> Void)?
    var progress = AttachmentProgress()

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
                            .disabled(progress.removing.contains(attachment.id))
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                // Files being stored (board #670): shown at once, with progress.
                ForEach(Array(progress.importing.enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
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

/// What the composer's attachments are doing while they await the writer
/// (board #670): files being stored, removals under way, and a send waiting
/// for them.
struct AttachmentProgress: Equatable {
    var importing: [String] = []
    var removing: Set<Int64> = []
    var sendWaits = false

    var isEmpty: Bool { importing.isEmpty }
}
