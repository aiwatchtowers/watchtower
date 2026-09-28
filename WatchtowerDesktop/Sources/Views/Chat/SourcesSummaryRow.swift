import SwiftUI
import WatchtowerCore

/// The one-line sources row under a finished answer: a small stack of kind
/// icons, "N sources", the most frequent groups, a chevron. Clicking it opens
/// the sources panel in the inspector. Always one line, whatever N is.
struct SourcesSummaryRow: View {
    let sources: [ChatSource]
    var onOpen: () -> Void

    var body: some View {
        let summary = ChatSourceGrouping.summary(sources)
        if !summary.kinds.isEmpty {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    iconStack(summary.kinds)
                    Text(summary.countLabel)
                        .fontWeight(.medium)
                    if !summary.topGroups.isEmpty {
                        Text(summary.topGroups)
                            .foregroundStyle(.secondary)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show sources")
            .accessibilityLabel("\(summary.countLabel). Show sources")
        }
    }

    private func iconStack(_ kinds: [String]) -> some View {
        HStack(spacing: -5) {
            ForEach(kinds, id: \.self) { kind in
                Image(systemName: Self.icon(kind))
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color(.windowBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35)))
            }
        }
        .accessibilityHidden(true)
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "slack": "number"
        case "jira": "ticket"
        case "email": "envelope"
        case "meeting": "waveform"
        case "document": "doc.text"
        case "person": "person.crop.circle"
        default: "link"
        }
    }
}
