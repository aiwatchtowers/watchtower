import ChatWire
import SwiftUI
import WatchtowerDesign

/// The `@` picker: people, issues, channels, targets and tracks the engine found for the query (`entity_search`).
struct MentionPicker: View {
    let hits: [ChatEntityHit]
    let onPick: (ChatEntityHit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(hits, id: \.self) { hit in
                Button { onPick(hit) } label: {
                    HStack(spacing: Spacing.regular) {
                        Image(systemName: Self.icon(hit.kind)).foregroundStyle(.secondary).frame(width: IconSize.composer)
                        Text(hit.label).lineLimit(1)
                        if !hit.detail.isEmpty {
                            Text(hit.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(Spacing.small)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row))
        .accessibilityIdentifier("chat.mentionPicker")
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "person": "person.crop.circle"
        case "channel": "number"
        case "jira_issue", "linear_issue": "ticket"
        case "target": "target"
        case "track": "point.topleft.down.to.point.bottomright.curvepath"
        default: "at"
        }
    }
}
