import AppKit
import ChatUI
import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// Workchat's feed on ChatUI (unified chat spec §9.2), shared by the pane and the subagent view: the owner's lines and
/// the agent's text are ChatUI's rows (`WorkchatFeedAdapter`), with their time and "via Watchtower" as the caption;
/// the `system` lines — Watchtower's own, the brief, notices, separators and subagent cards — are `SessionChatRow`.
@MainActor
struct WorkchatFeed {
    let entries: [SessionFeedEntry]
    let markdown: SessionFeedMarkdownCache
    let expandedEvents: Set<String>
    let onOpenSubagent: (SessionFeedSubagent) -> Void
    let onToggle: (String) -> Void
    /// Sends a question card's answers as the owner's next line; nil (a subagent's run, a finished session) shows the
    /// card read-only.
    var onAnswer: ((String) -> Void)?
    /// The agent works: no card is answered meanwhile.
    var isWorking = false
    /// A line the owner sent is still on its way (not yet read back in the feed): a card just answered takes no
    /// second answer.
    var answerPending = false
    /// An artifact card opens the viewer.
    var onOpenArtifact: (ChatArtifactContent) -> Void = { _ in }

    var messages: [ChatFeed.Message] { WorkchatFeedAdapter.messages(entries) }

    /// The entry behind each message id.
    var entriesByMessage: [Int64: SessionFeedEntry] {
        Dictionary(entries.map { (WorkchatFeedAdapter.messageID($0.id), $0) }) { _, last in last }
    }

    func context() -> ChatFeedContext {
        let byID = entriesByMessage
        var rowActions = ChatRowActions()
        rowActions.copy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        rowActions.allowsEdit = false
        rowActions.allowsRegenerate = false
        rowActions.allowsCopy = false
        var partActions = ChatPartActions(openArtifact: onOpenArtifact)
        partActions.openURL = { url in if AllowedURLSchemes.permits(url) { NSWorkspace.shared.open(url) } }
        partActions.copy = rowActions.copy
        partActions.showsSources = false
        partActions.offersContinue = false
        if let onAnswer { partActions.sendFixedText = onAnswer }
        var context = ChatFeedContext(isTurnRunning: onAnswer == nil || isWorking || answerPending,
                                      partActions: partActions,
                                      rowActions: rowActions)
        context.compact = true
        context.margins = EdgeInsets(top: Spacing.medium, leading: Spacing.medium, bottom: Spacing.medium,
                                     trailing: Spacing.medium)
        context.captionView = { message in
            let parts = byID[message.id].map(WorkchatFeedAdapter.caption) ?? []
            guard !parts.isEmpty else { return nil }
            return AnyView(HStack(spacing: Spacing.compact) {
                ForEach(parts, id: \.self) { Text($0) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary))
        }
        context.ownerHeader = { message in
            byID[message.id].flatMap(WorkchatFeedAdapter.askHeader).map { header in
                AnyView(VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(header.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let title = header.title { Text(title).font(.callout.weight(.semibold)) }
                })
            }
        }
        let (markdown, expanded, open, toggle) = (markdown, expandedEvents, onOpenSubagent, onToggle)
        context.systemRow = { message in
            guard let entry = byID[message.id] else { return AnyView(EmptyView()) }
            return AnyView(
                SessionChatRow(entry: entry, blocks: markdown.blocks(for: entry), expanded: expanded.contains(entry.id),
                               onOpenSubagent: { entry.subagent.map(open) }, onToggle: { toggle(entry.id) })
                    .equatable()
            )
        }
        return context
    }
}

/// A `system` line of the session chat (Watchtower's own line, the brief, a
/// notice, a separator, a subagent card). `Equatable` on its data only +
/// `.equatable()` at the call site: an unchanged row never re-renders its
/// markdown. The closures are rebuilt per render and stay out of `==`.
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
        case "watchtower":
            watchtowerBubble
        case "brief":
            DisclosureGroup {
                markdown.padding(.top, Spacing.small)
            } label: {
                Text("Watchtower: brief").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
        case "event":
            eventLine
        case "separator":
            HStack(spacing: Spacing.regular) {
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
        VStack(spacing: Spacing.small) {
            Button {
                onToggle?()
            } label: {
                HStack(spacing: Spacing.compact) {
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

    /// A line Watchtower wrote to the agent for the owner: on the owner's side, marked "via Watchtower".
    private var watchtowerBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                markdown
                    .padding(.horizontal, Spacing.cozy)
                    .padding(.vertical, Spacing.compact)
                    .background(Color.accentColor.opacity(ChipTint.fillOpacity),
                                in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
                HStack(spacing: Spacing.compact) {
                    Text("via Watchtower")
                    if let at = entry.at { Text(at, format: .dateTime.hour().minute()) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func subagentCard(_ subagent: SessionFeedSubagent) -> some View {
        Button {
            onOpenSubagent?()
        } label: {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.tight) {
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
            .padding(Spacing.cozy)
            .card()
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
