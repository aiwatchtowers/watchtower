import SwiftUI
import WatchtowerCore

/// A track read in full as an Inbox card (`InboxTrackPane`): its narrative,
/// a custom track's controls and activity, its links, the card's buttons
/// (`TrackCardActions`) and its chat below.
struct TrackDetailView: View {
    let card: InboxTrackCard
    let viewModel: TracksViewModel
    /// A custom track's toggle, instruction and scans (the C3 seam).
    let controls: any CustomTrackControlling
    let isWriting: Bool
    let onDone: () -> Void
    let onStopWatching: () -> Void
    /// A stopped track's Restore (the undo of Stop watching).
    let onRestore: () -> Void
    let onCommand: (InboxCardCommand) -> Void
    let workbenches: [Workbench]
    @Environment(AppState.self) private var appState
    @Environment(\.markdownNavScreens) private var navScreens
    /// The track's chat conversation, resolved on appear. The chat itself
    /// lives in `AppState.embeddedChatCenter`: leaving the track never stops
    /// a reply.
    @State private var chatConversationID: Int64?
    @State private var chatError: String?
    /// The track whose chat the pane shows; a create landing for another
    /// one is dropped.
    @State private var chatShownKey: String?
    /// Tracks whose first chat is being written (board #670): a spinner
    /// stands in for the chat meanwhile.
    @State private var chatCreates = ChatCreateGate()
    /// The chat is unfolded (per track: the pane is rebuilt per track).
    @State private var chatOpen = false
    @State private var cardState: TrackCardState
    @State private var isMakingTask = false
    /// A failed Make a Task or Delete.
    @State private var cardError: String?
    @State private var linkedTargets: [Target] = []
    @State private var jiraIssues: [JiraIssue] = []
    @State private var trackStates: [TrackState] = []
    @State private var expandedTrackStateIDs: Set<Int> = []
    @State private var timelineVM: CustomTrackTimelineViewModel?

    init(
        card: InboxTrackCard,
        viewModel: TracksViewModel,
        controls: any CustomTrackControlling,
        isWriting: Bool = false,
        onDone: @escaping () -> Void,
        onStopWatching: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onCommand: @escaping (InboxCardCommand) -> Void,
        workbenches: [Workbench]
    ) {
        self.card = card
        self.viewModel = viewModel
        self.controls = controls
        self.isWriting = isWriting
        self.onDone = onDone
        self.onStopWatching = onStopWatching
        self.onRestore = onRestore
        self.onCommand = onCommand
        self.workbenches = workbenches
        _cardState = State(initialValue: TrackCardState(track: card.track))
    }

    private var track: Track { card.track }

    var body: some View {
        // The chat starts folded, so the card's own buttons stay above the
        // fold; **Open chat** gives it the lower part of the pane.
        Group {
            if chatOpen {
                VSplitView {
                    content.frame(minHeight: 200)
                    VStack(spacing: 0) {
                        chatDisclosure
                        chatPane
                    }
                    .frame(minHeight: 200, idealHeight: 300)
                }
            } else {
                VStack(spacing: 0) {
                    content
                    Divider()
                    chatDisclosure
                }
            }
        }
        .onAppear {
            if let db = appState.databaseManager {
                openChat(db: db)
                loadLinkedTargets(db: db)
                loadJiraIssues(db: db)
                loadTrackStates(db: db)
                startTimelineIfCustom(db: db)
            }
        }
        .onDisappear {
            timelineVM?.stop()
            timelineVM = nil
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                headerSection
                textSection
                requesterSection
                contextSection
                customActivitySection
                blockingSection
                subItemsSection
                decisionSection
                decisionOptionsSection
                participantsSection
                historySection
                sourceRefsSection
                relatedDigestsSection
                linkedTasksSection
                jiraIssuesSection
                dueDateSection
                tagsSection
                actionsSection
            }
            .frame(maxWidth: InboxCardColumn<EmptyView>.readableWidth, alignment: .leading)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// **Open chat** / **Hide chat**: the track's chat folds under one row.
    private var chatDisclosure: some View {
        HStack {
            Button {
                chatOpen.toggle()
            } label: {
                Label(chatOpen ? "Hide chat" : "Open chat",
                      systemImage: chatOpen ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.kitQuiet)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.small)
    }

    /// The embedded chat, or its spinner or failure.
    @ViewBuilder
    private var chatPane: some View {
        if let db = appState.databaseManager, let chatConversationID {
            let engine = trackChatEngine(db: db, conversationID: chatConversationID)
            TrackChatSection(engine: engine, trackID: track.id)
                .embeddedChatVisibility(engine.spec.key, in: appState.embeddedChatCenter)
        } else if chatCreates.isCreating(String(track.id)) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let chatError {
            Label(chatError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Tone.error)
                .padding(Spacing.small)
        } else {
            Spacer()
        }
    }

    // MARK: - Chat

    /// An existing conversation opens at once (a read); a track's first chat
    /// is created off the main thread (board #670) and shows once written,
    /// unless the pane moved on to another track meanwhile.
    private func openChat(db: DatabaseManager) {
        let requested = track
        let key = String(requested.id)
        chatShownKey = key
        do {
            if let existing = try TrackChatSurface.existingConversationID(for: requested, dbPool: db.dbPool) {
                chatConversationID = existing
                chatError = nil
                return
            }
        } catch {
            chatOpenFailed(error, trackID: requested.id)
            return
        }
        chatConversationID = nil
        // A create already under way for this track shows its chat when it lands.
        guard chatCreates.begin(key) else { return }
        Task {
            defer { chatCreates.end(key) }
            do {
                let id = try await TrackChatSurface.conversationID(for: requested, dbPool: db.dbPool)
                guard chatShownKey == key else { return }
                chatConversationID = id
                chatError = nil
            } catch {
                guard chatShownKey == key else { return }
                chatOpenFailed(error, trackID: requested.id)
            }
        }
    }

    private func chatOpenFailed(_ error: Error, trackID: Int) {
        chatConversationID = nil
        NSLog("TrackDetailView: opening the chat of track %d failed: %@", trackID, String(describing: error))
        chatError = "Couldn't open the chat: \(error.localizedDescription)"
    }

    /// A finished reply can change what the track shows (the daemon's
    /// re-scan reads the same conversation), so the list reloads after it.
    private func trackChatEngine(db: DatabaseManager, conversationID: Int64) -> EmbeddedChatEngine {
        let engine = appState.embeddedChatCenter.engine(
            for: TrackChatSurface.spec(track: track, conversationID: conversationID, dbPool: db.dbPool))
        engine.onTurnFinished = { [weak viewModel] _ in viewModel?.load() }
        return engine
    }

    // MARK: - Custom-track Activity

    /// A custom track's controls, then its activity timeline. Standalone
    /// tracks (no linked target) still see the timeline; only the per-event
    /// "Apply" is gated on the track being linked (the VM's `canApplyActions`).
    @ViewBuilder
    private var customActivitySection: some View {
        if track.isCustom {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                CustomTrackControlsSection(track: track, controls: controls, state: $cardState) {
                    viewModel.load()
                }
                if let vm = timelineVM {
                    CustomTrackTimelineView(viewModel: vm, scanRowOpen: $cardState.scanRowOpen,
                                            showsEarlier: $cardState.showsEarlier)
                }
            }
        }
    }

    /// Permanently deletes a custom track (and its events) through the
    /// seam; the Inbox reads again so the card leaves and the next one shows.
    private func deleteTrack() {
        let track = track
        let trackID = track.id
        Task {
            do {
                try await controls.delete(track)
            } catch {
                NSLog("TrackDetailView: deleting track %d failed: %@", trackID, String(describing: error))
                cardError = "Couldn't delete the watch: \(error.localizedDescription)"
                return
            }
            // Only once it is gone: a reply in its chat stops with it.
            appState.embeddedChatCenter.dropContext(type: TrackChatSurface.contextType, id: String(trackID))
            viewModel.load()
            await appState.actionStripViewModel?.refresh()
        }
    }

    /// Builds and starts the custom-track timeline VM; a confirmed proposed
    /// action is applied through the CLI (the registry).
    private func startTimelineIfCustom(db: DatabaseManager) {
        guard track.isCustom, timelineVM == nil,
              let runner = appState.trackActionRunnerOverride
                ?? ProcessCLIRunner.makeDefault() as (any CLIRunnerProtocol)? else { return }
        let vm = CustomTrackTimelineViewModel(
            track: track,
            dbManager: db,
            actionRunner: runner,
            controls: controls,
            scanCenter: appState.trackScanCenter
        )
        vm.start()
        timelineVM = vm
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                priorityBadge
                ownershipBadge
                categoryBadge

                if track.hasUpdates {
                    Label("Updated", systemImage: "bell.badge.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule())
                }

                Spacer()

                Text(track.updatedAgo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Main track text as title
            Text(viewModel.resolveUserIDs(track.text))
                .font(.title3)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Text (main body)

    @ViewBuilder
    private var textSection: some View {
        // Channels
        let channels = track.decodedChannelIDs
        if !channels.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(channels, id: \.self) { chID in
                    let name = viewModel.channelName(for: chID) ?? chID
                    if let url = viewModel.slackChannelURL(channelID: chID) {
                        Link(destination: url) {
                            Text("#\(name)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text("#\(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Requester

    @ViewBuilder
    private var requesterSection: some View {
        if !track.requesterName.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Requested by: \(viewModel.resolveUserIDs(track.requesterName))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context

    @ViewBuilder
    private var contextSection: some View {
        if !track.context.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context")
                    .font(.headline)
                Text(viewModel.resolveUserIDs(track.context))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Blocking

    @ViewBuilder
    private var blockingSection: some View {
        if !track.blocking.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Blocking")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                Text(viewModel.resolveUserIDs(track.blocking))
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Sub-items

    @ViewBuilder
    private var subItemsSection: some View {
        let items = track.decodedSubItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let progress = track.subItemsProgress
                HStack {
                    Text("Sub-items")
                        .font(.headline)
                    Spacer()
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Progress bar
                if progress.total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.green)
                                .frame(
                                    width: geo.size.width
                                        * CGFloat(progress.done)
                                        / CGFloat(progress.total)
                                )
                        }
                    }
                    .frame(height: 6)
                }

                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button {
                        Task {
                            await viewModel.toggleSubItem(track, at: index)
                            await refreshInbox()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(
                                systemName: item.isDone
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(item.isDone ? .green : .secondary)
                            .font(.subheadline)

                            Text(item.text)
                                .font(.subheadline)
                                .strikethrough(item.isDone)
                                .foregroundStyle(item.isDone ? .secondary : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.pendingWrites.isPending(
                        TracksViewModel.subItemKey(trackID: track.id, index: index)
                    ))
                }
            }
        }
    }

    // MARK: - Decision summary

    @ViewBuilder
    private var decisionSection: some View {
        if !track.decisionSummary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Decision")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(viewModel.resolveUserIDs(track.decisionSummary))
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Decision options

    @ViewBuilder
    private var decisionOptionsSection: some View {
        let options = track.decodedDecisionOptions
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Options")
                    .font(.headline)

                ForEach(options) { opt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(opt.option)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if !opt.supporters.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "hand.thumbsup.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                Text(opt.supporters.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !opt.pros.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Text("+")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .frame(width: 12)
                                Text(opt.pros)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !opt.cons.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Text("-")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .frame(width: 12)
                                Text(opt.cons)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Participants

    @ViewBuilder
    private var participantsSection: some View {
        let people = track.decodedParticipants
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Participants")
                    .font(.headline)

                ForEach(people) { person in
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(stanceColor(person.stance))
                            .font(.subheadline)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let stance = person.stance, !stance.isEmpty {
                                Text(stance)
                                    .font(.caption)
                                    .foregroundStyle(stanceColor(stance))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Source refs (key messages)

    @ViewBuilder
    private var sourceRefsSection: some View {
        let refs = track.decodedSourceRefs
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Key Messages")
                    .font(.headline)

                ForEach(refs) { ref in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                            .frame(width: 16)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.resolveUserIDs(ref.author))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(ref.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        // Slack link for the message — prefer channel_id from ref, fall back to track's first channel
                        let refChannelID = ref.channelID ?? track.decodedChannelIDs.first
                        if let chID = refChannelID, !ref.ts.isEmpty {
                            if let url = viewModel.slackMessageURL(
                                channelID: chID, messageTS: ref.ts, threadTS: ref.threadTS
                            ) {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Open in Slack")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Related Digests (expandable)

    @ViewBuilder
    private var relatedDigestsSection: some View {
        let digestIDs = track.decodedRelatedDigestIDs
        if !digestIDs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Related Digests")
                    .font(.headline)

                ForEach(digestIDs, id: \.self) { digestID in
                    LinkedDigestRow(
                        digestID: digestID,
                        viewModel: viewModel,
                        appState: appState
                    )
                }
            }
        }
    }

    // MARK: - Due date

    @ViewBuilder
    private var dueDateSection: some View {
        if let formatted = track.dueDateFormatted {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(track.isOverdue ? .red : .secondary)
                Text("Due: \(formatted)")
                    .font(.caption)
                    .foregroundStyle(track.isOverdue ? .red : .secondary)
                if track.isOverdue {
                    Text("OVERDUE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }
            }
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagsSection: some View {
        let trackTags = track.decodedTags
        if !trackTags.isEmpty {
            HStack(spacing: 4) {
                ForEach(trackTags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            TrackCardActions(
                subject: InboxCardSubject(track: card, events: timelineVM?.events ?? []),
                link: slackURL,
                isCustom: track.isCustom,
                isStopped: track.isDismissed,
                linkedTargetID: track.linkedTargetID,
                navScreens: navScreens,
                workbenches: workbenches,
                isWriting: isWriting,
                isMakingTask: isMakingTask,
                confirmingDelete: $cardState.confirmingDelete,
                onCommand: onCommand,
                onDone: onDone,
                onStopWatching: onStopWatching,
                onRestore: onRestore,
                onMakeTask: makeTask,
                onGoToTarget: { appState.navigateToTarget($0) },
                onDelete: deleteTrack
            )
            if let cardError {
                Label(cardError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Tone.status("red"))
            }
            if let dbManager = appState.databaseManager {
                FeedbackButtons(
                    entityType: "track",
                    entityID: String(track.id),
                    dbManager: dbManager
                )
            }
        }
    }

    /// Make a Task (R9): a target from the track's prefill, opened in Targets.
    private func makeTask() {
        guard !isMakingTask else { return }
        isMakingTask = true
        let track = track
        Task {
            defer { isMakingTask = false }
            cardError = await appState.makeTask(fromTrack: track)
        }
    }

    /// The Inbox's list shows this track too: it reads again after an edit
    /// here, so its row and this card agree.
    private func refreshInbox() async {
        await appState.actionStripViewModel?.refresh()
    }

    private var slackURL: URL? {
        let refs = track.decodedSourceRefs
        if let first = refs.first, !first.ts.isEmpty {
            let chID = first.channelID ?? track.decodedChannelIDs.first
            if let chID, !chID.isEmpty {
                return viewModel.slackMessageURL(
                    channelID: chID,
                    messageTS: first.ts,
                    threadTS: first.threadTS
                )
            }
        }
        if let chID = track.decodedChannelIDs.first, !chID.isEmpty {
            return viewModel.slackChannelURL(channelID: chID)
        }
        return nil
    }

    // MARK: - Jira Issues

    @ViewBuilder
    private var jiraIssuesSection: some View {
        if !jiraIssues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Linked Jira Issues")
                    .font(.headline)

                ForEach(jiraIssues, id: \.key) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            JiraBadgeView(
                                issue: issue,
                                siteURL: viewModel.jiraSiteURL,
                                isExpanded: true
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.summary)
                                    .font(.subheadline)
                                    .lineLimit(2)

                                HStack(spacing: 8) {
                                    if !issue.sprintName.isEmpty {
                                        Label(issue.sprintName, systemImage: "arrow.triangle.2.circlepath")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let dueText = jiraIssueDueText(issue) {
                                        Label(dueText, systemImage: "calendar")
                                            .font(.caption2)
                                            .foregroundStyle(
                                                isJiraIssueOverdue(issue) ? .red : .secondary
                                            )
                                    }
                                }
                            }

                            Spacer()
                        }

                        // Linked issues (blocks/blocked by/relates to)
                        JiraLinkedIssuesView(
                            issueKey: issue.key,
                            siteURL: viewModel.jiraSiteURL
                        )
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.indigo.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func loadJiraIssues(db: DatabaseManager) {
        jiraIssues = (try? db.dbPool.read { database in
            try JiraQueries.fetchIssuesForTrack(database, trackID: track.id)
        }) ?? []
    }

    private func jiraIssueDueText(_ issue: JiraIssue) -> String? {
        guard !issue.dueDate.isEmpty else { return nil }
        // dueDate is typically "YYYY-MM-DD" or ISO8601
        let dateStr = String(issue.dueDate.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        let relative = DateFormatter()
        relative.dateStyle = .medium
        relative.timeStyle = .none
        return relative.string(from: date)
    }

    private func isJiraIssueOverdue(_ issue: JiraIssue) -> Bool {
        guard !issue.dueDate.isEmpty,
              issue.statusCategory != "done" else { return false }
        let dateStr = String(issue.dueDate.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return false }
        return date < Date()
    }

    // MARK: - Linked Targets

    @ViewBuilder
    private var linkedTasksSection: some View {
        if !linkedTargets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Targets")
                    .font(.headline)

                ForEach(linkedTargets) { target in
                    Button {
                        appState.navigateToTarget(target.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: target.statusIcon)
                                .foregroundStyle(taskStatusColor(target.status))
                                .font(.subheadline)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.text)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 6) {
                                    Text(target.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            taskStatusColor(target.status).opacity(0.15),
                                            in: Capsule()
                                        )

                                    if let due = target.dueDateFormatted {
                                        Label(due, systemImage: "calendar")
                                            .font(.caption2)
                                            .foregroundStyle(target.isOverdue ? .red : .secondary)
                                    }
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadLinkedTargets(db: DatabaseManager) {
        linkedTargets = (try? db.dbPool.read { database in
            try TargetQueries.fetchBySourceRef(database, sourceType: "track", sourceID: String(track.id))
        }) ?? []
    }

    /// Loads the narrative-state history for this track. See TRACKS-06.
    private func loadTrackStates(db: DatabaseManager) {
        trackStates = (try? db.dbPool.read { database in
            try TrackStateQueries.fetchByTrackID(database, trackID: track.id)
        }) ?? []
    }

    // MARK: - History (TRACKS-06)

    private var historySection: some View {
        Group {
            if !trackStates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("History")
                            .font(.headline)
                        Text("(\(trackStates.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(trackStates) { state in
                        trackStateRow(state)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackStateRow(_ state: TrackState) -> some View {
        let isExpanded = expandedTrackStateIDs.contains(state.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isExpanded {
                    expandedTrackStateIDs.remove(state.id)
                } else {
                    expandedTrackStateIDs.insert(state.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(state.createdAgo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(state.sourceLabel)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(state.isManual ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                        .foregroundStyle(state.isManual ? .blue : .purple)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !state.text.isEmpty {
                        Text(state.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    if !state.context.isEmpty {
                        Text(state.context)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 12) {
                        Label(state.priority, systemImage: "flag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(state.ownership, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(state.category, systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private func taskStatusColor(_ status: String) -> Color {
        switch status {
        case "todo": .secondary
        case "in_progress": .blue
        case "blocked": .red
        case "done": .green
        case "dismissed": .gray
        case "snoozed": .purple
        default: .secondary
        }
    }

    // MARK: - Badges

    private var priorityBadge: some View {
        Menu {
            ForEach(["high", "medium", "low"], id: \.self) { priority in
                Button {
                    Task {
                        await viewModel.updatePriority(track, to: priority)
                        await refreshInbox()
                    }
                } label: {
                    if priority == track.priority {
                        Label(priority.capitalized, systemImage: "checkmark")
                    } else {
                        Text(priority.capitalized)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
                Text(track.priority.capitalized)
                    .font(.caption)
                    .foregroundStyle(priorityColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(priorityColor.opacity(0.1), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var ownershipBadge: some View {
        Menu {
            ForEach(["mine", "delegated", "watching"], id: \.self) { own in
                Button {
                    Task {
                        await viewModel.updateOwnership(track, to: own)
                        await refreshInbox()
                    }
                } label: {
                    if own == track.ownership {
                        Label(ownershipLabel(own), systemImage: "checkmark")
                    } else {
                        Text(ownershipLabel(own))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: ownershipIcon)
                    .font(.system(size: 9))
                Text(track.ownershipLabel)
                    .font(.caption)
            }
            .foregroundStyle(ownershipColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ownershipColor.opacity(0.1), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var categoryBadge: some View {
        Text(track.categoryLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.1), in: Capsule())
    }

    // MARK: - Helpers

    private var priorityColor: Color {
        switch track.priority {
        case "high": .red
        case "low": .blue
        default: .orange
        }
    }

    private var ownershipColor: Color {
        switch track.ownership {
        case "mine": .green
        case "delegated": .purple
        case "watching": .secondary
        default: .secondary
        }
    }

    private var ownershipIcon: String {
        switch track.ownership {
        case "mine": "person.fill"
        case "delegated": "arrow.right.circle.fill"
        case "watching": "eye.fill"
        default: "circle"
        }
    }

    private func ownershipLabel(_ value: String) -> String {
        switch value {
        case "mine": return "Mine"
        case "delegated": return "Delegated"
        case "watching": return "Watching"
        default: return value.capitalized
        }
    }

    private func stanceColor(_ stance: String?) -> Color {
        switch stance {
        case "driver": .green
        case "supporter": .blue
        case "blocker": .red
        case "reviewer": .purple
        case "neutral": .secondary
        default: .secondary
        }
    }
}

// MARK: - Linked Digest Row (expandable)

private struct LinkedDigestRow: View {
    let digestID: Int
    let viewModel: TracksViewModel
    let appState: AppState
    @State private var isExpanded = false
    @State private var digest: Digest?
    @State private var channelName: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let digest {
                VStack(alignment: .leading, spacing: 8) {
                    if !digest.summary.isEmpty {
                        Text(digest.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }

                    let decisions = digest.parsedDecisions
                    if !decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Decisions")
                                .font(.caption)
                                .fontWeight(.semibold)
                            ForEach(decisions) { decision in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .frame(width: 12)
                                        .padding(.top, 2)
                                    Text(decision.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let dbManager = appState.databaseManager {
                        FeedbackButtons(
                            entityType: "digest",
                            entityID: String(digestID),
                            dbManager: dbManager
                        )
                    }
                }
                .padding(.leading, 4)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.blue)
                if let channelName {
                    Text("#\(channelName)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Text("Digest #\(digestID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let digest {
                    Text(digest.isRead ? "read" : "unread")
                        .font(.caption2)
                        .foregroundStyle(digest.isRead ? .green : .orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (digest.isRead ? Color.green : Color.orange).opacity(0.1),
                            in: Capsule()
                        )
                }
                Spacer()
            }
        }
        .onAppear { loadDigest() }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { loadDigest() }
        }
    }

    private func loadDigest() {
        guard digest == nil else { return }
        digest = viewModel.fetchDigest(id: digestID)
        if let loaded = digest {
            channelName = viewModel.channelName(for: loaded.channelID)
        }
    }
}
