import SwiftUI
import WatchtowerCore

/// Detail view for a single decision, over the consolidated ledger: essence,
/// status badge, Supersede/Reverse actions, 👍/👎 + comment, the mentions
/// chronology (deep links reused from `IdeaDetailPane.mentionURL`), and the
/// per-idea Discuss chat (spec B3: "Discuss chat stays available, same
/// context_type='idea'") — decisions are no longer reachable via the Ideas
/// tab (Task 8 narrowed it to ideas/notes), so this pane is the only place
/// left to discuss one. Mounts the existing `IdeaDiscussSection`/
/// `IdeaChatViewModel` the same way `IdeaDetailPane` does, rather than
/// forking a decision-specific chat VM.
struct DecisionDetailView: View {
    let idea: Idea
    let viewModel: DigestViewModel
    var onClose: (() -> Void)?
    @Environment(AppState.self) private var appState
    @State private var comment: String
    @State private var rating: Int?
    @State private var mentions: [IdeaMention] = []
    @State private var mentionsLoaded = false
    @State private var mentionsError: String?
    @State private var jiraSiteURL: String?

    // Discuss chat state — the IdeaDetailPane precedent: not hoisted further
    // since this view is already `.id(idea.id)`'d at its call site
    // (DigestListView), so this @State resets per decision selection change.
    @State private var discussExpanded = false
    @State private var discussVM: IdeaChatViewModel?

    init(idea: Idea, viewModel: DigestViewModel, onClose: (() -> Void)? = nil) {
        self.idea = idea
        self.viewModel = viewModel
        self.onClose = onClose
        _comment = State(initialValue: idea.ratingComment)
        _rating = State(initialValue: idea.ownerRating == 0 ? nil : idea.ownerRating)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    essenceSection
                    mentionsSection
                    discussSection
                }
                .padding()
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
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            badge(statusLabel, color: statusColor)

            Text(idea.title)
                .font(.title3)
                .fontWeight(.semibold)
                .textSelection(.enabled)

            Spacer()

            if let date = TimeFormatting.parseISO(idea.lastMentionAt) {
                Text(TimeFormatting.shortDateTime(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let onClose {
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
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

    private var statusLabel: String {
        idea.statusRaw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var statusColor: Color {
        switch idea.status {
        case .active: .green
        case .superseded: .purple
        case .reversed, .rejected: .red
        default: .orange
        }
    }

    // MARK: - Essence

    // A hand-created decision (IdeaCreateSheet) or an odd malformed mined row
    // can carry an empty essence — an empty Text view still reserves a line
    // of vertical space, so skip it rather than render a blank gap.
    @ViewBuilder
    private var essenceSection: some View {
        if !idea.essence.isEmpty {
            Text(idea.essence)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // Reuses `IdeaDetailPane.mentionURL` (the tested source of truth for
    // which mention kinds get a real deep link) instead of re-deriving the
    // per-source URL rules here.
    @ViewBuilder
    private func mentionLink(_ mention: IdeaMention) -> some View {
        if let url = IdeaDetailPane.mentionURL(mention, jiraSiteURL: jiraSiteURL) {
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

    private func loadMentions() async {
        guard let db = appState.databaseManager else {
            mentions = []
            mentionsError = nil
            mentionsLoaded = true
            return
        }
        do {
            mentions = try await db.dbPool.read { conn in try IdeaQueries.fetchMentions(conn, ideaID: idea.id) }
            mentionsError = nil
        } catch {
            // "No mentions recorded." is a real, meaningful state — a decision
            // can genuinely have none. A failed read must not impersonate it.
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

            TextField("Comment to teach the assistant…", text: $comment)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Clears the owner's typed comment only once the write actually landed —
    /// wiping it on a failed write throws away something they cannot get back.
    private func submitRating(_ value: Int) {
        guard viewModel.setRating(id: idea.id, rating: value, comment: comment) else { return }
        comment = ""
        rating = value
    }

    @ViewBuilder
    private var statusActionsRow: some View {
        HStack(spacing: 8) {
            if idea.status == .active {
                Button {
                    viewModel.supersede(id: idea.id)
                } label: {
                    Label("Supersede", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    viewModel.reverse(id: idea.id)
                } label: {
                    Label("Reverse", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }
}

/// Colored badge showing decision importance (read-only).
struct ImportanceBadge: View {
    let importance: String

    private var color: Color {
        switch importance {
        case "high": .red
        case "low": .gray
        default: .orange
        }
    }

    private var label: String {
        switch importance {
        case "high": "High"
        case "low": "Low"
        default: "Medium"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }
}

/// Clickable importance badge — single styled control with a popover picker.
struct EditableImportanceBadge: View {
    let importance: String
    let isCorrected: Bool
    let onChange: (String) -> Void

    private static let levels = ["high", "medium", "low"]
    @State private var showPicker = false

    private func colorFor(_ level: String) -> Color {
        switch level {
        case "high": .red
        case "low": .gray
        default: .orange
        }
    }

    private func labelFor(_ level: String) -> String {
        switch level {
        case "high": "High"
        case "low": "Low"
        default: "Medium"
        }
    }

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(colorFor(importance))
                    .frame(width: 8, height: 8)
                Text(labelFor(importance))
                    .font(.caption)
                    .foregroundStyle(colorFor(importance))
                if isCorrected {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(colorFor(importance))
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colorFor(importance).opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.levels, id: \.self) { level in
                    Button {
                        onChange(level)
                        showPicker = false
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorFor(level))
                                .frame(width: 8, height: 8)
                            Text(labelFor(level))
                                .font(.callout)
                            Spacer()
                            if level == importance {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if level != Self.levels.last {
                        Divider().padding(.horizontal, 6)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(width: 140)
        }
        .help(isCorrected ? "Importance changed (click to adjust)" : "Click to change importance")
    }
}
