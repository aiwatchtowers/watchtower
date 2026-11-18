import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// An artifact block of the answer (the client-derived `artifact` part, D14): a card that opens the viewer. CHAT-05:
/// the card and the viewer only show, open and copy — nothing here sends.
struct ArtifactPartView: View {
    let draft: ArtifactDraft
    let context: ChatPartContext

    private var stored: ChatFeed.Artifact? { context.artifacts.first { $0.key == draft.key } }
    private var isWriting: Bool { !draft.isComplete }

    var body: some View {
        Button { context.actions.openArtifact(ChatArtifactContent(draft: draft, stored: stored)) } label: {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: Self.icon(for: draft.kind))
                    .font(.title3)
                    .frame(width: IconSize.tile)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(isWriting ? "Writing \(draft.title)…" : draft.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.regular)
                if isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.cozy)
            .frame(maxWidth: PaneWidth.narrowPage, alignment: .leading)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
            .contentShape(RoundedRectangle(cornerRadius: Radius.container))
        }
        .buttonStyle(.plain)
        .disabled(isWriting)
        .help("Open \(draft.title)")
        .accessibilityIdentifier("chat.artifact.\(draft.key)")
    }

    private var subtitle: String {
        let label = Self.kindLabel(draft.kind)
        guard let version = stored?.version else { return label }
        return "\(label) · v\(version)"
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "table": "tablecells"
        case "email": "envelope"
        case "slack": "number"
        case "event": "calendar"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "html": "play.rectangle"
        default: "doc.richtext"
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "table": "Table"
        case "email": "Email draft"
        case "slack": "Slack message draft"
        case "event": "Event draft"
        case "code": "Code"
        case "html": "HTML page"
        default: "Document"
        }
    }
}
