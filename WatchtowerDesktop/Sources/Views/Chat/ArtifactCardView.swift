import SwiftUI
import WatchtowerCore

struct ArtifactCardView: View {
    let draft: ArtifactDraft
    let isWriting: Bool
    var version: Int?
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(for: draft.kind))
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isWriting ? "Writing \(draft.title)…" : draft.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sidebar.right").foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separatorColor).opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("Open \(draft.title)")
    }

    private var subtitle: String {
        let label = Self.kindLabel(draft.kind)
        guard let version else { return label }
        return "\(label) · v\(version)"
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "table": return "tablecells"
        case "email": return "envelope"
        case "slack": return "number"
        case "event": return "calendar"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.richtext"
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "table": return "Table"
        case "email": return "Email draft"
        case "slack": return "Slack message draft"
        case "event": return "Event draft"
        case "code": return "Code"
        default: return "Document"
        }
    }
}
