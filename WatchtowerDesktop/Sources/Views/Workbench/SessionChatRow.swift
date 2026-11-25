import AppKit
import ChatUI
import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// Workchat's feed on ChatUI (unified chat spec §9.2), shared by the pane and the subagent view: the owner's lines and
/// the agent's text are ChatUI's rows (`WorkchatFeedAdapter`), with their time and "via Watchtower" as the caption;
/// the `system` lines — Watchtower's own, the brief, notices and separators — are `SessionChatRow`. Subagent markers
/// draw nothing here (#2065): they live in the live line's 👥 list.
@MainActor
struct WorkchatFeed {
    let entries: [SessionFeedEntry]
    let markdown: SessionFeedMarkdownCache
    let expandedEvents: Set<String>
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
    /// Each Claude Code conversation's transcript directory (`SessionFeedStore.transcriptDirs`): an agent's output
    /// opens from its `subagents/` there; a conversation not listed reveals it in Finder.
    var transcriptDirs: [String: String] = [:]
    /// The conversation of rows that carry none: a subagent's run takes its parent's.
    var parentConversation: String?
    /// A click on a highlighted span of the agent's text (`WorkchatHighlights`); nil = the spans are only coloured.
    var onHighlight: ((AgentTextHighlights.Span, Int64) -> Void)?
    /// Whether a path in an agent message (by id) is a file of the session's folders: only such a path is coloured.
    var resolvesPath: ((String, Int64) -> Bool)?
    /// The Workchat's attachments folder (`WorkchatAttachmentStore.root`): only an owner's image there is read for
    /// its thumbnail; one anywhere else is a chip (`WorkchatOwnerImages`).
    var attachmentsRoot: String?

    /// Puts `text` on the general pasteboard (a row's Copy, a highlighted hash or command).
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whose output a row's Open output reads: the row's own conversation (after /clear or a resume, an older task's
    /// output is in its own session's temp dir), else the parent's, and the project the feed read it from.
    func outputSource(_ entry: SessionFeedEntry) -> (claudeSessionID: String?, projectDir: String?) {
        let session = entry.conversation.isEmpty ? parentConversation : entry.conversation
        return (session, session.flatMap { transcriptDirs[$0] })
    }

    var messages: [ChatFeed.Message] { WorkchatFeedAdapter.messages(entries, ownerSplit: ownerImages) }

    /// An owner line's shown text and images, split once per entry text (`SessionFeedMarkdownCache.ownerImages`).
    func ownerImages(_ entry: SessionFeedEntry) -> WorkchatOwnerImages {
        markdown.ownerImages(id: entry.id, text: entry.text, attachmentsRoot: attachmentsRoot)
    }

    /// The entry behind each message id.
    var entriesByMessage: [Int64: SessionFeedEntry] {
        Dictionary(entries.map { (WorkchatFeedAdapter.messageID($0.id), $0) }) { _, last in last }
    }

    func context() -> ChatFeedContext {
        let byID = entriesByMessage
        var rowActions = ChatRowActions()
        rowActions.copy = Self.copy
        rowActions.allowsEdit = false
        rowActions.allowsRegenerate = false
        rowActions.allowsCopy = false
        var partActions = ChatPartActions(openArtifact: onOpenArtifact)
        partActions.openURL = { url in if AllowedURLSchemes.permits(url) { NSWorkspace.shared.open(url) } }
        partActions.copy = rowActions.copy
        partActions.showsSources = false
        partActions.offersContinue = false
        partActions.openHighlight = onHighlight
        partActions.resolvesPath = resolvesPath
        if let onAnswer { partActions.sendFixedText = onAnswer }
        var context = ChatFeedContext(isTurnRunning: onAnswer == nil || isWorking || answerPending,
                                      partActions: partActions,
                                      rowActions: rowActions)
        context.compact = true
        // The agent's refs, hashes, paths and commands in IDE-style colours (spec 2026-11-24-workchat-polish §2).
        context.highlightsAgentText = true
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
        let (markdown, expanded, toggle) = (markdown, expandedEvents, onToggle)
        let (openArtifact, feed) = (onOpenArtifact, self)
        context.ownerFooter = { message in
            guard let entry = byID[message.id], entry.kind == "owner" else { return nil }
            let images = feed.ownerImages(entry).images
            return images.isEmpty ? nil : AnyView(WorkchatOwnerImagesView(images: images))
        }
        context.systemRow = { message in
            guard let entry = byID[message.id] else { return AnyView(EmptyView()) }
            let source = feed.outputSource(entry)
            return AnyView(
                SessionChatRow(entry: entry, blocks: markdown.blocks(for: entry), expanded: expanded.contains(entry.id),
                               outputSession: source.claudeSessionID, outputProjectDir: source.projectDir,
                               onToggle: { toggle(entry.id) },
                               onOpenOutput: { path in
                                   AgentFinishedRow.openOutput(path, claudeSessionID: source.claudeSessionID,
                                                               projectDir: source.projectDir, openArtifact: openArtifact)
                               })
                .equatable()
            )
        }
        return context
    }
}

/// A `system` line of the session chat (Watchtower's own line, the brief, a
/// notice, a separator). `Equatable` on its data only +
/// `.equatable()` at the call site: an unchanged row never re-renders its
/// markdown. The closures are rebuilt per render and stay out of `==`.
struct SessionChatRow: View, Equatable {
    let entry: SessionFeedEntry
    /// The parsed text, from the pane's `SessionFeedMarkdownCache`.
    let blocks: [MarkdownBlock]
    /// An event's body is shown (events only).
    var expanded = false
    /// Whose output Open output reads and the project of its agents' transcripts (part of `==`, so a late value
    /// re-renders the row).
    var outputSession: String?
    var outputProjectDir: String?
    var onToggle: (() -> Void)?
    /// Open output on a task's row (`AgentFinishedRow`); nil hides it.
    var onOpenOutput: ((String) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.blocks == rhs.blocks && lhs.expanded == rhs.expanded
            && lhs.outputSession == rhs.outputSession && lhs.outputProjectDir == rhs.outputProjectDir
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
        case "peer":
            if let bubble = PeerBubblePresentation.bubble(for: entry) {
                PeerBubbleCard(bubble: bubble, blocks: entry.peer?.kind == "started" ? nil : blocks)
            }
        default:
            EmptyView()
        }
    }

    private var markdown: some View {
        MarkdownBlocksView(blocks: blocks).textSelection(.enabled)
    }

    /// A Claude Code notice: a task notification from a newer CLI is the quiet agent-finished row
    /// (`AgentFinishedRow`); any other (a message from another session, an older CLI's task) one centered grey line,
    /// a click shows its body.
    @ViewBuilder private var eventLine: some View {
        if let task = entry.task {
            AgentFinishedRow(presentation: AgentFinishedPresentation(task: task, fallbackTitle: entry.title ?? ""),
                             outputFile: task.outputFile, expanded: expanded, onToggle: onToggle,
                             onOpenOutput: onOpenOutput)
        } else {
            noticeLine
        }
    }

    private var noticeLine: some View {
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
