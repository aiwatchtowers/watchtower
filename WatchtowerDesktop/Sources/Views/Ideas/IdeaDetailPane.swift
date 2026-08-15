import SwiftUI
import WatchtowerCore

// MARK: - IdeaDetailPane
//
// The rich single-idea review screen on the right of the Ideas registry's
// master-detail split (modeled on SituationReviewPane). Shows kind/status
// badges, the title, a needs-review banner, the essence text, a similar-to
// hint when the miner flagged one, the mentions chronology, a bottom rating
// row (👍/👎 + teaching comment), and a status-dependent action bar. All
// mutating actions are delegated to the owning IdeasView via closures.
struct IdeaDetailPane: View {
    @Environment(AppState.self) private var appState

    let idea: Idea
    /// Every idea currently loaded in the review queue + registry — the
    /// candidate pool for the merge picker. Passed as plain data (not the
    /// view model) to keep this pane's dependency surface small, the
    /// SituationReviewPane precedent.
    let allIdeas: [Idea]
    let onApprove: () -> Void
    let onReject: () -> Void
    let onActivate: () -> Void
    /// nil = an indefinite "not now" (no snooze date).
    let onNotNow: (Date?) -> Void
    let onDrop: () -> Void
    let onMerge: (Int) -> Void
    let onConvert: () -> Void
    let onRating: (Int, String) -> Bool
    let onDelete: () -> Void

    @State private var comment: String
    @State private var rating: Int?
    @State private var mentions: [IdeaMention] = []
    @State private var mentionsLoaded = false
    @State private var mentionsError: String?
    @State private var jiraSiteURL: String?
    @State private var showMergeSheet = false
    @State private var mergePreselectID: Int?
    @State private var showDeleteConfirmation = false

    // Discuss chat state lives here (not hoisted like the situation pane's)
    // because IdeasView already applies `.id(idea.id)` at this pane's call
    // site, so this @State already resets per idea selection change.
    @State private var discussExpanded = false
    @State private var discussVM: IdeaChatViewModel?

    init(
        idea: Idea,
        allIdeas: [Idea],
        onApprove: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onNotNow: @escaping (Date?) -> Void,
        onDrop: @escaping () -> Void,
        onMerge: @escaping (Int) -> Void,
        onConvert: @escaping () -> Void,
        onRating: @escaping (Int, String) -> Bool,
        onDelete: @escaping () -> Void
    ) {
        self.idea = idea
        self.allIdeas = allIdeas
        self.onApprove = onApprove
        self.onReject = onReject
        self.onActivate = onActivate
        self.onNotNow = onNotNow
        self.onDrop = onDrop
        self.onMerge = onMerge
        self.onConvert = onConvert
        self.onRating = onRating
        self.onDelete = onDelete
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

            if discussExpanded, let discussVM {
                Divider()
                IdeaDiscussInputBar(chatVM: discussVM)
            }

            Divider()
            actionBar
        }
        .task(id: idea.id) { await loadMentions() }
        .task { jiraSiteURL = JiraConfigHelper.readSiteURL() }
        .sheet(isPresented: $showMergeSheet) {
            IdeaMergeSheet(
                candidates: allIdeas,
                excludingID: idea.id,
                preselectedID: mergePreselectID,
                onMerge: onMerge
            )
        }
        .confirmationDialog("Delete this \(kindLabel.lowercased())?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its mentions and chat will be removed permanently.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                badge(kindLabel, color: kindColor)
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

    private var kindLabel: String {
        switch idea.kind {
        case .idea: return "Idea"
        case .decision: return "Decision"
        case .note: return "Note"
        }
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
                Button("Merge") {
                    mergePreselectID = similarToID
                    showMergeSheet = true
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Mentions chronology

    @ViewBuilder
    private var mentionsSection: some View {
        Divider()
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
                Text(mention.author.isEmpty ? mention.sourceKind.rawValue.capitalized : mention.author)
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
        if let url = mentionURL(mention) {
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
            }
            .foregroundStyle(.secondary)
            .help("Open in \(mention.sourceKind.rawValue.capitalized)")
        } else {
            Text(mention.sourceKind.rawValue.capitalized)
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
    /// Gmail and meeting mentions render a plain source label.
    ///
    /// Static so the URL-building rules are testable without a view.
    static func mentionURL(_ mention: IdeaMention, jiraSiteURL: String?) -> URL? {
        switch mention.sourceKind {
        case .slack:
            let parts = mention.ref.split(separator: "|")
            guard parts.count == 2 else { return nil }
            let ts = parts[1].replacingOccurrences(of: ".", with: "")
            return URL(string: "https://slack.com/archives/\(rawSlackChannelID(parts[0]))/p\(ts)")
        case .jira:
            guard let jiraSiteURL, !jiraSiteURL.isEmpty else { return nil }
            return URL(string: "\(jiraSiteURL)/browse/\(mention.ref)")
        case .meeting, .gmail, .owner:
            return nil
        }
    }

    /// Strips the Slack multi-account namespace ("<accountID>:") that
    /// `channels.id`/`messages.channel_id` carry since migration 00048 — Slack's
    /// own archives URL wants the bare channel id. Anything that isn't a
    /// leading integer followed by ':' is passed through untouched, so a
    /// pre-migration bare id still works.
    private static func rawSlackChannelID(_ namespaced: Substring) -> Substring {
        guard let colon = namespaced.firstIndex(of: ":"),
              !namespaced[namespaced.startIndex..<colon].isEmpty,
              namespaced[namespaced.startIndex..<colon].allSatisfy(\.isNumber)
        else { return namespaced }
        return namespaced[namespaced.index(after: colon)...]
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
            mentions = try await db.dbPool.read { conn in try IdeaQueries.fetchMentions(conn, ideaID: idea.id) }
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
                isExpanded: $discussExpanded,
                chatVM: $discussVM
            )
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            ratingRow
            statusActionsRow
        }
        .padding(12)
    }

    private var ratingRow: some View {
        HStack(spacing: 8) {
            Button {
                submitRating(1)
            } label: {
                Image(systemName: rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(rating == 1 ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.bordered)
            .help("Helpful")

            Button {
                submitRating(-1)
            } label: {
                Image(systemName: rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(rating == -1 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.bordered)
            .help("Not helpful")

            TextField("Comment to teach the secretary…", text: $comment)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Clears the owner's typed comment only once the write actually landed —
    /// wiping it on a failed write throws away something they cannot get back.
    private func submitRating(_ value: Int) {
        guard onRating(value, comment) else { return }
        comment = ""
        rating = value
    }

    /// Buttons offered depend on kind+status per the lifecycle in the design
    /// doc: idea (mined) proposed → active|rejected; active ↔ not_now;
    /// active/not_now → converted|dropped; decision proposed → active|rejected;
    /// active → superseded|reversed; note born active, only dropped/merged
    /// apply; merge is an owner action available on any non-terminal item.
    @ViewBuilder
    private var statusActionsRow: some View {
        HStack(spacing: 8) {
            if idea.status == .proposed {
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
            }

            if idea.kind == .idea, idea.status == .active {
                notNowMenu
                Button(action: onConvert) {
                    Label("Convert to Target", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                Button("Drop", role: .destructive, action: onDrop)
                    .buttonStyle(.bordered)
            }

            if idea.kind == .idea, idea.status == .notNow {
                Button("Activate", action: onActivate)
                    .buttonStyle(.borderedProminent)
                Button(action: onConvert) {
                    Label("Convert to Target", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                Button("Drop", role: .destructive, action: onDrop)
                    .buttonStyle(.bordered)
            }

            if idea.kind == .note, idea.status == .active {
                Button("Drop", role: .destructive, action: onDrop)
                    .buttonStyle(.bordered)
            }

            // A rejected or dropped item is not frozen: the consolidator flags
            // it needs_review when the same idea comes up again (IDEA-04), and
            // it then shows in "For review". Without an action here the owner
            // could see the flag but never clear it — the item would sit in the
            // review queue permanently. Reconsidering is the whole point of the
            // resurfacing flag.
            if idea.status == .rejected || idea.status == .dropped {
                Button("Activate", action: onActivate)
                    .buttonStyle(.borderedProminent)
            }

            if canMerge {
                Button {
                    mergePreselectID = idea.similarToID
                    showMergeSheet = true
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            // Offered for every kind and every status: the owner can throw
            // anything away, including entries no status action applies to.
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Delete permanently")
        }
    }

    private var notNowMenu: some View {
        Menu {
            Button("1 week") { onNotNow(Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
            Button("1 month") { onNotNow(Calendar.current.date(byAdding: .month, value: 1, to: Date())) }
            Button("No date") { onNotNow(nil) }
        } label: {
            Label("Not now", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var canMerge: Bool {
        idea.status != .merged && idea.status != .converted
    }
}

// MARK: - IdeaMergeSheet
//
// Picks a target idea to merge the current one into. Pre-fills the search
// with the miner's `similar_to_id` hint when present; otherwise the owner
// searches the active/proposed registry by title.
private struct IdeaMergeSheet: View {
    let candidates: [Idea]
    let excludingID: Int
    let preselectedID: Int?
    let onMerge: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedID: Int?

    private var eligible: [Idea] {
        candidates.filter { $0.id != excludingID && ($0.status == .active || $0.status == .proposed) }
    }

    private var filtered: [Idea] {
        guard !searchText.isEmpty else { return eligible }
        return eligible.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Merge into…")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            TextField("Search ideas…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            List(filtered, selection: $selectedID) { candidate in
                Text(candidate.title).tag(candidate.id)
            }
            .frame(minHeight: 220)

            Divider()
            HStack {
                Spacer()
                Button("Merge") {
                    if let selectedID {
                        onMerge(selectedID)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedID == nil)
            }
            .padding(12)
        }
        .frame(width: 420, height: 380)
        .onAppear {
            selectedID = preselectedID
            if let preselectedID, let match = candidates.first(where: { $0.id == preselectedID }) {
                searchText = match.title
            }
        }
    }
}
