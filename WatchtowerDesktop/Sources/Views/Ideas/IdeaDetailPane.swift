import SwiftUI
import WatchtowerCore

// MARK: - IdeaDetailPane
//
// The rich single-idea review screen: the Inbox's idea card (`InboxIdeaPane`)
// and, until it leaves, the Ideas registry's detail. Shows kind/status
// badges, the title, a needs-review banner, the essence text, a similar-to
// hint when the miner flagged one, the mentions chronology, a bottom rating
// row (👍/👎 + teaching comment), and the verdict bar (`IdeaActionBar`). All
// mutating actions are delegated through `IdeaActions`.
struct IdeaDetailPane: View {
    @Environment(AppState.self) private var appState

    let idea: Idea
    /// Every idea the caller has loaded — the candidate pool for the inline
    /// merge row. Passed as plain data (not the view model) to keep this
    /// pane's dependency surface small.
    let allIdeas: [Idea]
    let actions: IdeaActions
    /// A verdict write is under way: the bar's buttons wait.
    let isWriting: Bool
    /// False while another prominent action is on screen (the Inbox's open
    /// New idea row): Approve drops to the regular style.
    let approveIsPrimary: Bool

    @State private var comment: String
    @State private var rating: Int?
    /// A rating write is waiting for the database (board #670).
    @State private var isRating = false
    @State private var mentions: [IdeaMention] = []
    @State private var mentionsLoaded = false
    @State private var mentionsError: String?
    @State private var jiraSiteURL: String?
    /// The chat conversations the `chat` mentions point at that still exist.
    @State private var liveChats: Set<Int64> = []
    /// The inline merge or delete row under the verdict buttons.
    @State private var openRow: IdeaActionRow?

    // Discuss chat state lives here (not hoisted like the situation pane's)
    // because every caller applies `.id(idea.id)` at this pane's call site,
    // so this @State already resets per idea selection change.
    @State private var discuss = IdeaDiscussState()

    init(idea: Idea, allIdeas: [Idea], actions: IdeaActions, isWriting: Bool = false, approveIsPrimary: Bool = true) {
        self.idea = idea
        self.allIdeas = allIdeas
        self.actions = actions
        self.isWriting = isWriting
        self.approveIsPrimary = approveIsPrimary
        _comment = State(initialValue: idea.ratingComment)
        _rating = State(initialValue: idea.ownerRating == 0 ? nil : idea.ownerRating)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if idea.needsReview {
                        reviewBanner
                    }
                    essenceSection
                    similarToRow
                    mentionsSection
                    discussSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let db = appState.databaseManager,
               let engine = discuss.engine(idea: idea, mentions: mentions, dbManager: db,
                                           center: appState.embeddedChatCenter) {
                Divider()
                EmbeddedChatComposer(engine: engine, placeholder: "Ask about this idea…",
                                     dictationTargetID: "chat.idea.\(idea.id)", density: .compact)
            }

            Divider()
            actionBar
        }
        .task(id: idea.id) { await loadMentions() }
        .task { jiraSiteURL = JiraConfigHelper.readSiteURL() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                badge(idea.kind.label, color: kindColor)
                badge(statusLabel, color: statusColor)
                Spacer()
                if let date = TimeFormatting.parseISO(idea.lastMentionAt) {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(idea.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var kindColor: Color {
        switch idea.kind {
        case .idea: return .yellow
        case .decision: return .purple
        case .note: return .secondary
        }
    }

    private var statusLabel: String {
        idea.statusRaw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var statusColor: Color {
        switch idea.status {
        case .proposed: return .orange
        case .active: return .green
        case .rejected, .reversed: return .red
        case .notNow, .dropped, .merged: return .gray
        case .converted: return .blue
        case .superseded: return .purple
        }
    }

    // MARK: - Review banner

    private var reviewBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Needs a second look", systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
            if !idea.reviewReason.isEmpty {
                Text(idea.reviewReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Essence

    private var essenceSection: some View {
        Text(idea.essence)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Similar-to hint

    @ViewBuilder
    private var similarToRow: some View {
        if let similarToID = idea.similarToID {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.blue)
                Text("Looks similar to #\(similarToID)")
                    .font(.callout)
                Spacer()
                Button("Merge…") { openRow = .merge(preselect: similarToID) }
                    .buttonStyle(.kitSecondary)
            }
            .padding(10)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Mentions chronology

    @ViewBuilder
    private var mentionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Mentions")
                .font(.headline)
                .padding(.bottom, 4)
            if !mentionsLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading mentions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let mentionsError {
                Label("Couldn't load mentions: \(mentionsError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if mentions.isEmpty {
                Text("No mentions recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mentions) { mention in
                    mentionBubble(mention)
                }
            }
        }
    }

    private func mentionBubble(_ mention: IdeaMention) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(mention.author.isEmpty ? mention.sourceKind.label : mention.author)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if let date = TimeFormatting.parseISO(mention.saidAt) {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                mentionLink(mention)
            }
            .padding(.top, 6)
            Text(mention.quote)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func mentionLink(_ mention: IdeaMention) -> some View {
        if let chat = mention.chatTarget {
            if liveChats.contains(chat.conversationID) {
                Button {
                    appState.openChatMessage(conversationID: chat.conversationID, messageID: chat.messageID)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.kitQuiet)
                .foregroundStyle(.secondary)
                .help("Open in Chat")
                .accessibilityLabel("Open in Chat")
            } else {
                Text("Chat deleted")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if let url = mentionURL(mention) {
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
            }
            .foregroundStyle(.secondary)
            .help("Open in \(mention.sourceKind.label)")
        } else {
            Text(mention.sourceKind.label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func mentionURL(_ mention: IdeaMention) -> URL? {
        Self.mentionURL(mention, jiraSiteURL: jiraSiteURL)
    }

    /// A wrong link is worse than no link — only the two sources with a
    /// well-established, easy-to-build URL (Slack's generic archives host, no
    /// workspace domain needed; Jira via the resolved site) get a Link.
    /// Gmail, IMAP, Linear and meeting mentions render a plain source label.
    ///
    /// Static so the URL-building rules are testable without a view.
    static func mentionURL(_ mention: IdeaMention, jiraSiteURL: String?) -> URL? {
        switch mention.sourceKind {
        case .slack:
            let parts = mention.ref.split(separator: "|")
            guard parts.count == 2 else { return nil }
            return SlackDeepLink.archives(channelID: String(parts[0]), messageTS: String(parts[1]))
        case .jira:
            guard let jiraSiteURL, !jiraSiteURL.isEmpty else { return nil }
            return URL(string: "\(jiraSiteURL)/browse/\(mention.ref)")
        case .meeting, .gmail, .imap, .linear, .owner, .chat:
            // A chat mention opens in the app (`mentionLink`), never a URL.
            return nil
        }
    }

    private func loadMentions() async {
        guard let db = appState.databaseManager else {
            mentions = []
            mentionsError = nil
            mentionsLoaded = true
            return
        }
        do {
            // An async read: a mentions list is unbounded, and a synchronous
            // dbPool.read here blocks the main actor behind whatever the daemon
            // is writing.
            let (read, chats) = try await db.dbPool.read { conn in
                let read = try IdeaQueries.fetchMentions(conn, ideaID: idea.id)
                let ids = read.compactMap { $0.chatTarget?.conversationID }
                return (read, try ChatConversationQueries.existingIDs(conn, ids: ids))
            }
            mentions = read
            liveChats = chats
            mentionsError = nil
        } catch {
            // "No mentions recorded." is a real, meaningful state — an idea can
            // genuinely have none. A failed read must not impersonate it.
            mentions = []
            mentionsError = error.localizedDescription
        }
        mentionsLoaded = true
    }

    // MARK: - Discuss

    @ViewBuilder
    private var discussSection: some View {
        if let dbManager = appState.databaseManager {
            IdeaDiscussSection(
                idea: idea,
                mentions: mentions,
                dbManager: dbManager,
                center: appState.embeddedChatCenter,
                state: $discuss
            )
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: Spacing.cozy) {
            ratingRow
            IdeaActionBar(idea: idea, allIdeas: allIdeas, actions: actions, openRow: $openRow,
                          isWriting: isWriting, approveIsPrimary: approveIsPrimary)
        }
        .padding(Spacing.medium)
    }

    private var ratingRow: some View {
        HStack(spacing: Spacing.regular) {
            Button {
                submitRating(1)
            } label: {
                Image(systemName: rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(rating == 1 ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.kitSecondary)
            .help("Helpful")

            Button {
                submitRating(-1)
            } label: {
                Image(systemName: rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(rating == -1 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.kitSecondary)
            .help("Not helpful")

            TextField("Comment to teach the assistant…", text: $comment)
                .textFieldStyle(.kit)
        }
    }

    /// Clears the owner's typed comment only once the write actually landed —
    /// wiping it on a failed write throws away something they cannot get back.
    /// A second press while the write waits does nothing, and text typed
    /// meanwhile stays (board #670).
    private func submitRating(_ value: Int) {
        guard !isRating else { return }
        isRating = true
        let sent = comment
        Task {
            defer { isRating = false }
            guard await actions.rating(value, sent) else { return }
            if comment == sent { comment = "" }
            rating = value
        }
    }
}

// MARK: - IdeaActions

/// The writes an idea card can ask for; the caller runs them through
/// `IdeasViewModel` (today's verdict writes). Each one is awaited, so the
/// caller can re-read its list after it.
struct IdeaActions {
    var approve: () async -> Void = {}
    var reject: () async -> Void = {}
    var activate: () async -> Void = {}
    /// The `snooze_until` date (`yyyy-MM-dd`, owner-local), or "" for no date.
    var notNow: (String) async -> Void = { _ in }
    var drop: () async -> Void = {}
    var merge: (Int) async -> Void = { _ in }
    var makeTask: () async -> Void = {}
    var supersede: () async -> Void = {}
    var reverse: () async -> Void = {}
    var rating: (Int, String) async -> Bool = { _, _ in false }
    var delete: () async -> Void = {}
}

/// The inline row open under the verdict buttons (no sheet, no dialog).
enum IdeaActionRow: Equatable {
    /// Pick the idea to merge into; `preselect` (the miner's similar-to hint)
    /// is listed first when it is a candidate.
    case merge(preselect: Int?)
    case delete
    /// **Reverse** on an active decision asks first, inline.
    case reverse
}

/// **Not now ▾**: until when.
enum IdeaNotNow: CaseIterable {
    case week, month, noDate

    var label: String {
        switch self {
        case .week: "1 week"
        case .month: "1 month"
        case .noDate: "No date"
        }
    }

    /// The owner-local calendar day the idea comes back, `yyyy-MM-dd`; ""
    /// for no date.
    func until(now: Date = Date(), calendar: Calendar = .current) -> String {
        let date: Date?
        switch self {
        case .week: date = calendar.date(byAdding: .day, value: 7, to: now)
        case .month: date = calendar.date(byAdding: .month, value: 1, to: now)
        case .noDate: date = nil
        }
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension Idea.Kind {
    /// "Idea", "Decision", "Note".
    var label: String {
        switch self {
        case .idea: "Idea"
        case .decision: "Decision"
        case .note: "Note"
        }
    }
}

// MARK: - IdeaActionBar

/// The idea card's buttons, by kind and status. An idea or note waiting for
/// a verdict (`awaitsVerdict`: proposed, or brought up again — IDEA-04)
/// gets **Approve**, **Make a Task**, **Not now ▾** and **Reject** (Make a
/// Task and Not now for ideas only; a note is born active and is never
/// snoozed or converted). A decision born in a chat waits the same way
/// (Approve, Not now, Reject, Merge — spec §1 of the chat-knowledge design).
/// A decided one keeps today's lifecycle: active ↔
/// not now, converted or dropped; a rejected or dropped one can be
/// activated again. Any other decision is informational — its status chip in the
/// header and, while active, **Supersede** / **Reverse**, never a verdict —
/// but keeps what the Ideas screen gave it: **Activate** when it sits in
/// rejected, dropped or not now (the way out of an IDEA-04 flag), Merge and
/// delete. Merge and delete open inline rows below the buttons.
struct IdeaActionBar: View {
    let idea: Idea
    let allIdeas: [Idea]
    let actions: IdeaActions
    @Binding var openRow: IdeaActionRow?
    /// A write is under way: every button waits (no second write).
    var isWriting = false
    var approveIsPrimary = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                buttons
                Spacer()
                Button(role: .destructive) {
                    openRow = openRow == .delete ? nil : .delete
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.kitIcon(isOn: openRow == .delete))
                .help("Delete permanently")
                .accessibilityLabel("Delete permanently")
            }
            .disabled(isWriting)
            switch openRow {
            case .merge(let preselect):
                IdeaMergeRow(idea: idea, candidates: allIdeas, preselect: preselect,
                             onMerge: { id in run { await actions.merge(id) } },
                             onCancel: { openRow = nil })
                    .disabled(isWriting)
            case .delete:
                IdeaDeleteRow(kind: idea.kind, onDelete: { run { await actions.delete() } },
                              onCancel: { openRow = nil })
                    .disabled(isWriting)
            case .reverse:
                IdeaReverseRow(onReverse: {
                    openRow = nil
                    run(actions.reverse)
                }, onCancel: { openRow = nil })
                    .disabled(isWriting)
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if idea.awaitsVerdict {
            verdictButtons
        } else if idea.kind == .decision {
            if idea.status == .active {
                Button { run(actions.supersede) } label: {
                    Label("Supersede", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.kitSecondary)
                Button(role: .destructive) {
                    openRow = openRow == .reverse ? nil : .reverse
                } label: {
                    Label("Reverse", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.kitSecondary)
            } else if [.rejected, .dropped, .notNow].contains(idea.status) {
                Button("Activate") { run(actions.activate) }
                    .buttonStyle(.kitSecondary)
            }
            mergeButton
        } else {
            decidedButtons
            mergeButton
        }
    }

    /// An item waiting for a verdict: Approve, then Make a Task (ideas), Not
    /// now (ideas and chat-born decisions), Reject and Merge.
    @ViewBuilder
    private var verdictButtons: some View {
        if approveIsPrimary {
            Button("Approve") { run(actions.approve) }
                .buttonStyle(.kitPrimary)
        } else {
            Button("Approve") { run(actions.approve) }
                .buttonStyle(.kitSecondary)
        }
        if idea.kind == .idea {
            makeTaskButton
        }
        if idea.kind != .note {
            notNowMenu
        }
        // One prominent action: Reject is a plain soft button beside Approve.
        Button("Reject", role: .destructive) { run(actions.reject) }
            .buttonStyle(.kitSecondary)
        mergeButton
    }

    @ViewBuilder
    private var decidedButtons: some View {
        switch (idea.kind, idea.status) {
        case (.idea, .active):
            makeTaskButton
            notNowMenu
            dropButton
        case (.idea, .notNow):
            Button("Activate") { run(actions.activate) }
                .buttonStyle(.kitPrimary)
            makeTaskButton
            dropButton
        case (.note, .active):
            dropButton
        case (_, .rejected), (_, .dropped):
            // IDEA-04: a rejected or dropped item the consolidator brings up
            // again must stay clearable; Activate is that way out.
            Button("Activate") { run(actions.activate) }
                .buttonStyle(.kitPrimary)
        default:
            EmptyView()
        }
    }

    private var makeTaskButton: some View {
        Button { run(actions.makeTask) } label: {
            Label("Make a Task", systemImage: "checkmark.circle")
        }
        .buttonStyle(.kitSecondary)
    }

    private var dropButton: some View {
        Button("Drop", role: .destructive) { run(actions.drop) }
            .buttonStyle(.kitDestructive)
    }

    private var notNowMenu: some View {
        Menu("Not now") {
            ForEach(IdeaNotNow.allCases, id: \.self) { choice in
                Button(choice.label) {
                    let until = choice.until()
                    run { await actions.notNow(until) }
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    @ViewBuilder
    private var mergeButton: some View {
        // Merge is an owner action on any item still in the registry.
        if idea.status != .merged && idea.status != .converted {
            Button {
                if case .merge = openRow { openRow = nil } else { openRow = .merge(preselect: idea.similarToID) }
            } label: {
                Label("Merge…", systemImage: "arrow.triangle.merge")
            }
            .buttonStyle(.kitSecondary)
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        Task { await action() }
    }
}

// MARK: - IdeaMergeRow

/// Merge inline: the ideas of the same kind still open (active or
/// proposed), searchable by title, each with its own **Merge**; the miner's
/// similar-to hint is listed first. Replaces the old merge sheet.
struct IdeaMergeRow: View {
    let idea: Idea
    let candidates: [Idea]
    let preselect: Int?
    let onMerge: (Int) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""

    /// Rows shown before the owner searches.
    static let shownLimit = 8

    /// Same kind, still open, never the idea itself; the hint first.
    static func eligible(_ candidates: [Idea], for idea: Idea, preselect: Int?) -> [Idea] {
        let open = candidates.filter {
            $0.id != idea.id && $0.kind == idea.kind && ($0.status == .active || $0.status == .proposed)
        }
        guard let preselect, let hint = open.first(where: { $0.id == preselect }) else { return open }
        return [hint] + open.filter { $0.id != preselect }
    }

    private var shown: [Idea] {
        let eligible = Self.eligible(candidates, for: idea, preselect: preselect)
        guard !searchText.isEmpty else { return Array(eligible.prefix(Self.shownLimit)) }
        return eligible.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Merge this \(idea.kind.label.lowercased()) into…")
                .font(.callout.weight(.semibold))
            TextField("Search ideas…", text: $searchText)
                .textFieldStyle(.kit)
            if shown.isEmpty {
                Text("Nothing to merge into.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { candidate in
                HStack(spacing: Spacing.regular) {
                    Text(verbatim: candidate.title)
                        .font(.callout)
                        .lineLimit(2)
                    if candidate.id == preselect {
                        Text("Similar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Merge") { onMerge(candidate.id) }
                        .buttonStyle(.kitSecondary)
                        .controlSize(.small)
                }
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.small)
                .kitRow(isSelected: false)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.kitQuiet)
            }
        }
        .padding(Spacing.medium)
        .card()
    }
}

// MARK: - IdeaReverseRow

/// Reverse inline: **Reverse** and **Cancel**, so a decision is never
/// reversed by one stray press.
struct IdeaReverseRow: View {
    let onReverse: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Text("Reverse this decision?")
                .font(.callout.weight(.semibold))
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.kitQuiet)
            Button("Reverse", role: .destructive, action: onReverse)
                .buttonStyle(.kitDestructive)
        }
        .padding(Spacing.medium)
        .card()
    }
}

// MARK: - IdeaDeleteRow

/// Delete inline: what goes with it, **Delete** and **Cancel**. Replaces the
/// old confirmation dialog.
struct IdeaDeleteRow: View {
    let kind: Idea.Kind
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Delete this \(kind.label.lowercased())?")
                    .font(.callout.weight(.semibold))
                Text("Its mentions, chat, and any duplicates merged into it will be removed permanently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.kitQuiet)
            Button("Delete", role: .destructive, action: onDelete)
                .buttonStyle(.kitDestructive)
        }
        .padding(Spacing.medium)
        .card()
    }
}
