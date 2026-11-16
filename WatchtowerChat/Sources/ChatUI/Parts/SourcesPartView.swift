import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The sources a reply cites (the `sources` part): one summary pill — kind icons, the count and the top groups — that
/// opens the full list (the Mac's inspector, the phone's sheet).
struct SourcesPartView: View {
    let payload: ChatSourcesPayload
    let context: ChatPartContext

    var body: some View {
        let sources = payload.sources.map(ChatSource.init(wire:))
        let summary = ChatSourceGrouping.summary(sources)
        if !summary.kinds.isEmpty {
            Button { context.actions.openSources(sources) } label: {
                HStack(spacing: Spacing.compact) {
                    HStack(spacing: Spacing.tight) {
                        ForEach(summary.kinds, id: \.self) { kind in
                            Image(systemName: Self.icon(kind)).font(.caption2)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(summary.countLabel).fontWeight(.medium).layoutPriority(1)
                    if !summary.topGroups.isEmpty {
                        Text(summary.topGroups).foregroundStyle(.secondary).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.tight)
                .background(Fill.rest, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.accessibilityLabel(summary))
            .accessibilityIdentifier("chat.sources")
        }
    }

    static func accessibilityLabel(_ summary: ChatSourcesSummary) -> String {
        let groups = summary.topGroups.isEmpty ? "" : ", mostly \(summary.topGroups)"
        return "\(summary.countLabel)\(groups). Show sources"
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "slack": "number"
        case "jira": "ticket"
        case "email": "envelope"
        case "meeting": "waveform"
        case "document": "doc.text"
        case "person": "person.crop.circle"
        case "web", PublishedLink.sourceKind: "globe"
        default: "link"
        }
    }
}

extension ChatSource {
    /// The wire's source as the shared grouping reads it.
    public init(wire source: ChatFeed.Source) {
        self.init(kind: source.kind, title: source.title, url: source.url, ref: source.ref, group: source.group,
                  snippet: source.snippet, date: source.date)
    }
}
