import SwiftUI
import WatchtowerCore

/// One message of the session chat, shared by the pane and the subagent
/// view. `Equatable` on its data only + `.equatable()` at the call site (the
/// `ChatMessageRow` pattern): an unchanged row never re-renders its markdown.
/// The closures are rebuilt per render and stay out of `==`.
struct SessionChatRow: View, Equatable {
    let entry: SessionFeedEntry
    /// The parsed text, from the pane's `SessionFeedMarkdownCache`.
    let blocks: [MarkdownBlock]
    /// An event's body is shown (events only).
    var expanded = false
    var onOpenSubagent: (() -> Void)?
    var onToggle: (() -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.blocks == rhs.blocks && lhs.expanded == rhs.expanded
    }

    /// Text the owner wrote (directly or through Watchtower) keeps its line
    /// breaks; the agent's text and event bodies keep markdown's soft breaks.
    static func lineBreaks(forKind kind: String) -> Bool {
        kind == "owner" || kind == "ask_answer" || kind == "watchtower"
    }

    var body: some View {
        switch entry.kind {
        case "owner":
            ownerBubble(label: nil, title: nil, caption: nil)
        case "ask_answer":
            ownerBubble(label: entry.askID.map { "Ask #\($0)" } ?? "Ask", title: entry.title, caption: "via Watchtower")
        case "watchtower":
            ownerBubble(label: nil, title: nil, caption: "via Watchtower")
        case "agent":
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    markdown
                    timeCaption
                }
                Spacer(minLength: 48)
            }
        case "brief":
            DisclosureGroup {
                markdown.padding(.top, 4)
            } label: {
                Text("Watchtower: brief").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
        case "event":
            eventLine
        case "separator":
            HStack(spacing: 8) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("New conversation").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }
        case "subagent":
            if let subagent = entry.subagent {
                subagentCard(subagent)
            }
        default:
            EmptyView()
        }
    }

    private var markdown: some View {
        MarkdownBlocksView(blocks: blocks).textSelection(.enabled)
    }

    /// A Claude Code notice (a background task finished, a message from
    /// another session): one centered grey line; a click shows its body.
    private var eventLine: some View {
        VStack(spacing: 4) {
            Button {
                onToggle?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entry.eventType == "teammate" ? "envelope" : "gearshape")
                    Text(entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Notice").lineLimit(1)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                markdown.frame(maxWidth: 520, alignment: .leading)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func ownerBubble(label: String?, title: String?, caption: String?) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                VStack(alignment: .leading, spacing: 4) {
                    if let label {
                        Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if let title, !title.isEmpty {
                        Text(title).font(.callout.weight(.semibold))
                    }
                    markdown
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 6) {
                    if let caption { Text(caption) }
                    if let at = entry.at { Text(at, format: .dateTime.hour().minute()) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var timeCaption: some View {
        if let at = entry.at {
            Text(at, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func subagentCard(_ subagent: SessionFeedSubagent) -> some View {
        Button {
            onOpenSubagent?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subagent.type.isEmpty ? "Subagent" : subagent.type).font(.callout.weight(.semibold))
                    if !subagent.description.isEmpty {
                        Text(subagent.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Text(subagent.status == "running" ? "Running" : subagent.status == "finished" ? "Finished" : "")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SessionFeedMarkdownCache {
    /// The parsed text of one row, with the row's line-break rule.
    func blocks(for entry: SessionFeedEntry) -> [MarkdownBlock] {
        switch entry.kind {
        case "subagent", "separator": []
        default: blocks(id: entry.id, text: entry.text, lineBreaks: SessionChatRow.lineBreaks(forKind: entry.kind))
        }
    }
}
