import SwiftUI
import WatchtowerCore

struct DigestListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: DigestViewModel?
    @State private var selectedDigestID: Int?
    @State private var selectedStreamID: Int?
    @State private var selectedRecordingID: Int64?
    @State private var selectedDecisionID: Int?
    @State private var searchText = ""
    @State private var showAllDigests = false
    @State private var showAllDecisions = false
    @State private var activeTab: DigestTab = .digests
    @State private var expandedDigestIDs: Set<Int> = []
    @State private var expandedDecisionIDs: Set<Int> = []
    @State private var isSelectMode = false
    @State private var checkedDigestIDs: Set<Int> = []
    @State private var showCreateDecisionSheet = false

    enum DigestTab: String, CaseIterable {
        case digests = "Digests"
        case decisions = "Decisions"
    }

    var body: some View {
        HStack(spacing: 0) {
            if let vm = viewModel {
                listPanel(vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let vm = viewModel {
                detailPanel(vm)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedDigestID)
        .animation(.easeInOut(duration: 0.25), value: selectedStreamID)
        .animation(.easeInOut(duration: 0.25), value: selectedRecordingID)
        .animation(.easeInOut(duration: 0.25), value: selectedDecisionID)
        .navigationTitle("Digests")
        .sheet(isPresented: $showCreateDecisionSheet) {
            if let ideasVM = appState.ideasViewModel {
                IdeaCreateSheet(vm: ideasVM, allowedKinds: [.decision])
            }
        }
        .onAppear {
            if let db = appState.databaseManager, viewModel == nil {
                viewModel = DigestViewModel(dbManager: db)
            }
            // Unconditional (not only on first creation): `.onDisappear`
            // stops the observations, so a re-appearing view holding the same
            // `@State` VM has to restart them. Both calls are idempotent.
            viewModel?.startObserving()
            if let id = appState.pendingDigestID {
                activeTab = .digests
                showAllDigests = true
                selectFeedDigest(id)
                appState.pendingDigestID = nil
            }
            if let id = appState.pendingDecisionID {
                activeTab = .decisions
                showAllDecisions = true
                selectDecision(id)
                appState.pendingDecisionID = nil
            }
        }
        .onDisappear {
            viewModel?.stopObserving()
        }
        .onChange(of: selectedDigestID) { _, newID in
            if let id = newID {
                viewModel?.markDigestRead(id)
            }
        }
        .onChange(of: appState.pendingDigestID) { _, newID in
            if let id = newID {
                activeTab = .digests
                showAllDigests = true
                selectFeedDigest(id)
                appState.pendingDigestID = nil
            }
        }
        .onChange(of: appState.pendingDecisionID) { _, newID in
            if let id = newID {
                activeTab = .decisions
                showAllDecisions = true
                selectDecision(id)
                appState.pendingDecisionID = nil
            }
        }
        .onChange(of: selectedDecisionID) { _, newID in
            if let id = newID,
               let idea = viewModel?.ledgerDecisions.first(where: { $0.id == id }),
               idea.seenAt == nil || idea.needsReview {
                viewModel?.markDecisionSeen(id: id)
            }
        }
    }

    /// Selects a Slack digest in the merged feed (row tap, `pendingDigestID`
    /// cross-tab nav) — clears the other two feed selections so only one
    /// detail pane shows at a time.
    private func selectFeedDigest(_ id: Int) {
        selectedDigestID = id
        selectedStreamID = nil
        selectedRecordingID = nil
    }

    /// Selects a ledger decision (`pendingDecisionID` cross-tab nav). Unlike
    /// `selectFeedDigest`, no sibling selection to clear here — switching
    /// `activeTab` to `.decisions` already clears the digest-family
    /// selections (see the direction-aware reset in `listPanel`'s
    /// `.onChange(of: activeTab)`).
    private func selectDecision(_ id: Int) {
        selectedDecisionID = id
    }

    private func selectFeedStream(_ id: Int) {
        selectedStreamID = id
        selectedDigestID = nil
        selectedRecordingID = nil
    }

    private func selectFeedRecording(_ id: Int64) {
        selectedRecordingID = id
        selectedDigestID = nil
        selectedStreamID = nil
    }

    @ViewBuilder
    private func detailPanel(_ vm: DigestViewModel) -> some View {
        switch activeTab {
        case .digests:
            feedDetailPanel(vm)
        case .decisions:
            if let id = selectedDecisionID, let idea = vm.ledgerDecisions.first(where: { $0.id == id }) {
                Divider()
                DecisionDetailView(
                    idea: idea, viewModel: vm
                ) { selectedDecisionID = nil }
                    .id(id)
                    .frame(minWidth: 400, idealWidth: 500)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// Digests-tab detail routing across the three feed sources. `.slack`
    /// resolves through `vm.digestByID` (a DB fetch, not a lookup into the
    /// possibly-paginated `vm.digests` cache) so a cross-tab `pendingDigestID`
    /// nav to an older, not-yet-paged-in digest still resolves — the
    /// pre-existing `digestByID` behavior this view relied on before the feed
    /// merge. `.stream`/`.meeting` look up their loaded (unpaginated) arrays.
    @ViewBuilder
    private func feedDetailPanel(_ vm: DigestViewModel) -> some View {
        if let id = selectedDigestID, let digest = vm.digestByID(id) {
            Divider()
            DigestDetailView(
                digest: digest,
                channelName: vm.channelName(for: digest),
                viewModel: vm
            ) { selectedDigestID = nil }
            .id(id)
            .frame(minWidth: 400, idealWidth: 500)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let id = selectedStreamID, let stream = vm.streamDigests.first(where: { $0.id == id }) {
            Divider()
            StreamDigestDetailView(digest: stream, viewModel: vm) { selectedStreamID = nil }
                .id(id)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let id = selectedRecordingID, let recording = vm.recordings.first(where: { $0.id == id }) {
            Divider()
            MeetingFeedDetailView(recording: recording) { selectedRecordingID = nil }
                .id(id)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// The merged feed, filtered by the read toggle and search text. Backs
    /// both the row list and (via `filteredDigests` below) the digests-only
    /// batch-select toolbar. Order follows `vm.feedEntries` (already sorted
    /// per `vm.sortOrder`).
    private var filteredFeedEntries: [DigestFeedEntry] {
        guard let vm = viewModel else { return [] }
        var items = vm.feedEntries
        if !showAllDigests {
            items = items.filter { !$0.isRead }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            items = items.filter {
                DigestFeedList.matches($0, query: query) { vm.channelName(for: $0) }
            }
        }
        return items
    }

    /// The Slack digests currently visible in the merged, filtered feed —
    /// the pool the digests-only batch-select toolbar (Select All / mark
    /// read / rate) operates over, so it never diverges from what search/
    /// unread filtering is actually showing.
    private var filteredDigests: [Digest] {
        filteredFeedEntries.compactMap { entry in
            if case .slack(let digest) = entry { return digest }
            return nil
        }
    }

    /// Groups the filtered feed into day sections in the order entries
    /// already appear (i.e. respecting `vm.sortOrder`) — see
    /// `DigestFeedList.group`, where the bucketing itself lives.
    private var groupedFeedEntries: [DigestFeedDaySection] {
        DigestFeedList.group(filteredFeedEntries)
    }

    private func listPanel(_ vm: DigestViewModel) -> some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $activeTab) {
                ForEach(DigestTab.allCases, id: \.self) { tab in
                    Text(tabLabel(tab, vm: vm)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .onChange(of: activeTab) { _, newTab in
                // Direction-aware: clear only the OTHER tab's selection, not
                // the new tab's own — a cross-tab pendingDigestID/
                // pendingDecisionID nav sets `activeTab` and that tab's
                // selection in the same update; clearing both groups
                // unconditionally would clobber the just-set selection once
                // this handler's own mutations trigger their own pass.
                switch newTab {
                case .digests:
                    selectedDecisionID = nil
                case .decisions:
                    selectedDigestID = nil
                    selectedStreamID = nil
                    selectedRecordingID = nil
                }
                searchText = ""
                isSelectMode = false
                checkedDigestIDs.removeAll()
            }

            // Search field + read filter
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SearchField(
                    text: $searchText,
                    placeholder: activeTab == .digests
                        ? "Filter digests..." : "Filter decisions..."
                )
                .frame(height: 22)

                Picker("", selection: activeReadBinding) {
                    Text("Unread").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .id(activeTab)

                sortMenu(vm)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Selection toolbar
            selectionToolbar(vm)

            // List content
            switch activeTab {
            case .digests:
                feedList(vm)
            case .decisions:
                DecisionsListView(
                    viewModel: vm,
                    selectedID: $selectedDecisionID,
                    expandedIDs: $expandedDecisionIDs,
                    searchText: $searchText,
                    showAll: $showAllDecisions
                )
            }
        }
        .frame(minWidth: 300, idealWidth: 360)
    }

    private var activeReadBinding: Binding<Bool> {
        switch activeTab {
        case .digests: $showAllDigests
        case .decisions: $showAllDecisions
        }
    }

    // MARK: - Selection Toolbar
    //
    // Batch select/mark-read/rate is a digests-only affordance: the ledger's
    // per-decision actions (seen/supersede/reverse/rating) live on the row
    // and detail pane instead. The Decisions segment reuses this same slot
    // for its "+" create button.

    @ViewBuilder
    private func selectionToolbar(_ vm: DigestViewModel) -> some View {
        switch activeTab {
        case .digests:
            if isSelectMode {
                activeSelectionBar(vm)
            } else {
                HStack {
                    Spacer()
                    Button {
                        isSelectMode = true
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        case .decisions:
            HStack {
                Spacer()
                if vm.unreadDecisionCount > 0 {
                    Button {
                        vm.markAllDecisionsSeen()
                    } label: {
                        Label("Mark all read", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    showCreateDecisionSheet = true
                } label: {
                    Label("New Decision", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func activeSelectionBar(_ vm: DigestViewModel) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleSelectAll()
            } label: {
                let allSelected = checkedDigestIDs.count == filteredDigests.count && !filteredDigests.isEmpty
                Label(
                    allSelected ? "Deselect All" : "Select All",
                    systemImage: allSelected ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption)
            }
            .buttonStyle(.borderless)

            if !checkedDigestIDs.isEmpty {
                selectionActions(vm, count: checkedDigestIDs.count)
            } else {
                Spacer()
            }

            Button {
                isSelectMode = false
                checkedDigestIDs.removeAll()
            } label: {
                Text("Cancel")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
    }

    @ViewBuilder
    private func selectionActions(_ vm: DigestViewModel, count: Int) -> some View {
        Text("\(count) selected")
            .font(.caption)
            .foregroundStyle(.secondary)

        Spacer()

        Button {
            markSelectedRead(vm)
        } label: {
            Label("Read", systemImage: "eye")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Mark selected as read")

        Button {
            submitSelectedFeedback(vm, rating: 1)
        } label: {
            Image(systemName: "hand.thumbsup")
                .foregroundStyle(.green)
        }
        .buttonStyle(.borderless)
        .help("Rate selected as good")

        Button {
            submitSelectedFeedback(vm, rating: -1)
        } label: {
            Image(systemName: "hand.thumbsdown")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .help("Rate selected as bad")
    }

    private func toggleSelectAll() {
        if checkedDigestIDs.count == filteredDigests.count {
            checkedDigestIDs.removeAll()
        } else {
            checkedDigestIDs = Set(filteredDigests.map(\.id))
        }
    }

    private func markSelectedRead(_ vm: DigestViewModel) {
        vm.markDigestsRead(checkedDigestIDs)
        checkedDigestIDs.removeAll()
    }

    private func submitSelectedFeedback(_ vm: DigestViewModel, rating: Int) {
        let ids = checkedDigestIDs.map { String($0) }
        vm.submitBatchFeedback(
            entityType: "digest", entityIDs: ids, rating: rating
        )
        checkedDigestIDs.removeAll()
        isSelectMode = false
    }

    // MARK: - Cross-source feed list

    /// The merged Digests-segment list: Slack digests, Gmail/Jira stream
    /// digests, and meeting recordings, day-grouped in the order
    /// `groupedFeedEntries` already sorted them. Only `.slack` rows carry the
    /// batch-select checkbox and the rich collapsible preview — batch
    /// select/mark-read/rate stays a digests-only affordance (see the
    /// `selectionToolbar` doc comment); stream/meeting rows are compact and
    /// route straight to their detail pane on tap.
    private func feedList(_ vm: DigestViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(groupedFeedEntries, id: \.day) { group in
                    Text(DigestFeedList.dayLabel(for: group.day))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    ForEach(group.entries) { entry in
                        feedRow(entry, vm: vm)
                            .onAppear {
                                if entry.id == filteredFeedEntries.last?.id {
                                    vm.loadMoreDigests()
                                }
                            }
                    }
                }
                if vm.isLoadingMoreDigests {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func feedRow(_ entry: DigestFeedEntry, vm: DigestViewModel) -> some View {
        switch entry {
        case .slack(let digest):
            digestListItem(digest, vm: vm)
        case .stream(let digest):
            streamFeedRow(digest)
        case .meeting(let recording):
            meetingFeedRow(recording)
        }
    }

    private func digestListItem(
        _ digest: Digest, vm: DigestViewModel
    ) -> some View {
        let isChecked = checkedDigestIDs.contains(digest.id)
        let isSelected = selectedDigestID == digest.id && !isSelectMode
        let bgColor: Color = isSelected
            ? Color.accentColor.opacity(0.15)
            : isChecked
                ? Color.accentColor.opacity(0.08)
                : !digest.isRead
                    ? Color.blue.opacity(0.06)
                    : Color.clear

        return HStack(spacing: 0) {
            if isSelectMode {
                Button {
                    toggleDigestChecked(digest.id)
                } label: {
                    Image(
                        systemName: isChecked
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(
                        isChecked ? Color.accentColor : Color.secondary
                    )
                    .font(.body)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 8)
            }

            digestRow(digest, vm: vm)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelectMode {
                        toggleDigestChecked(digest.id)
                    } else {
                        selectFeedDigest(digest.id)
                    }
                }
        }
        .padding(.horizontal, isSelectMode ? 4 : 10)
        .padding(.vertical, 6)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
    }

    /// Compact row for a Gmail/Jira stream digest — source badge, scope, and
    /// the first topic's title as a preview (the full topic list lives in
    /// `StreamDigestDetailView`). No batch-select checkbox: see the
    /// `feedList` doc comment.
    private func streamFeedRow(_ digest: StreamDigest) -> some View {
        let isSelected = selectedStreamID == digest.id
        let topics = digest.parsedTopics
        let bgColor: Color = isSelected
            ? Color.accentColor.opacity(0.15)
            : !digest.isRead
                ? Color.blue.opacity(0.06)
                : Color.clear

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !digest.isRead {
                    Circle().fill(Color.blue).frame(width: 6, height: 6)
                }
                streamSourceBadge(digest.source)
                if !digest.scope.isEmpty {
                    Text(digest.scope)
                        .font(.subheadline)
                        .fontWeight(digest.isRead ? .regular : .medium)
                        .lineLimit(1)
                }
                Spacer()
                if let date = TimeFormatting.parseISO(digest.createdAt) {
                    Text(TimeFormatting.shortDateTime(from: date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let firstTopic = topics.first {
                Text(firstTopic.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if topics.count > 1 {
                Text("+\(topics.count - 1) more topic\(topics.count - 1 == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { selectFeedStream(digest.id) }
    }

    private func streamSourceBadge(_ source: String) -> some View {
        let isJira = source == "jira"
        let color: Color = isJira ? .indigo : .red
        return Label(isJira ? "Jira" : "Gmail", systemImage: isJira ? "ticket" : "envelope")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    /// Compact row for a meeting recording — title, has-recap badge, and a
    /// snippet preview. Always renders as read (no unread concept for
    /// recordings, see `DigestFeedEntry.isRead`).
    private func meetingFeedRow(_ recording: RecordingListItem) -> some View {
        let isSelected = selectedRecordingID == recording.id
        let bgColor: Color = isSelected ? Color.accentColor.opacity(0.15) : Color.clear

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Meeting", systemImage: "video")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
                Text(recording.eventTitle ?? recording.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if recording.hasRecap {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Has a recap")
                }
                Spacer()
                if let date = recording.createdDate {
                    Text(TimeFormatting.shortDateTime(from: date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !recording.snippet.isEmpty {
                Text(recording.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { selectFeedRecording(recording.id) }
    }

    private func toggleDigestChecked(_ id: Int) {
        if checkedDigestIDs.contains(id) {
            checkedDigestIDs.remove(id)
        } else {
            checkedDigestIDs.insert(id)
        }
    }

    private func toggleDigestExpanded(_ id: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedDigestIDs.contains(id) {
                expandedDigestIDs.remove(id)
            } else {
                expandedDigestIDs.insert(id)
                viewModel?.markDigestRead(id)
            }
        }
    }

    private func digestRow(_ digest: Digest, vm: DigestViewModel) -> some View {
        let expanded = expandedDigestIDs.contains(digest.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(digestTypeLabel(digest.type))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(digestTypeColor(digest.type))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        digestTypeColor(digest.type).opacity(0.12), in: Capsule()
                    )

                Text(
                    vm.channelName(for: digest).map { "#\($0)" }
                        ?? "Cross-channel"
                )
                .font(.subheadline)
                .fontWeight(digest.isRead ? .regular : .medium)
                .lineLimit(1)

                if !digest.channelID.isEmpty {
                    StarToggleButton(
                        isStarred: vm.isChannelStarred(digest.channelID)
                    ) {
                        vm.toggleStarredChannel(digest.channelID)
                    }
                }

                Spacer()

                Text(TimeFormatting.shortDateTime(fromUnix: digest.periodTo))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    toggleDigestExpanded(digest.id)
                } label: {
                    Image(
                        systemName: expanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
            }

            if !digest.summary.isEmpty {
                Text(digest.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }

            HStack(spacing: 10) {
                if digest.messageCount > 0 {
                    Label("\(digest.messageCount)", systemImage: "message")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                let topicCount = digest.parsedTopics.count
                if topicCount > 0 {
                    Label("\(topicCount)", systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                let decisionCount = digest.parsedDecisions.count
                if decisionCount > 0 {
                    Label(
                        "\(decisionCount)",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }

                let actionCount = digest.parsedTracks.count
                if actionCount > 0 {
                    Label("\(actionCount)", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            if expanded {
                digestExpandedContent(digest, vm: vm)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func digestExpandedContent(
        _ digest: Digest, vm: DigestViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            let topics = digest.parsedTopics
            if !topics.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Color.accentColor.opacity(0.1), in: Capsule()
                            )
                    }
                }
            }

            let decisions = digest.parsedDecisions
            if !decisions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Decisions", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)

                    ForEach(decisions) { decision in
                        HStack(alignment: .top, spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    decisionImportanceColor(
                                        decision.resolvedImportance
                                    )
                                )
                                .frame(width: 2, height: 14)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(decision.text)
                                    .font(.caption)
                                    .lineLimit(2)
                                if let by = decision.by, !by.isEmpty {
                                    Text(by)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            let actions = digest.parsedTracks
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tracks", systemImage: "checkmark.circle")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)

                    ForEach(actions) { item in
                        HStack(alignment: .top, spacing: 4) {
                            Image(
                                systemName: item.status == "done"
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(
                                item.status == "done" ? .green : .secondary
                            )
                            .font(.caption2)
                            .padding(.top, 1)
                            Text(item.text)
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                }
            }

            Button {
                selectFeedDigest(digest.id)
            } label: {
                Label("Open details", systemImage: "arrow.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Helpers

    private func decisionImportanceColor(_ importance: String) -> Color {
        switch importance {
        case "high": .red
        case "low": .gray
        default: .orange
        }
    }

    private func digestTypeLabel(_ type: String) -> String {
        switch type {
        case "channel": "Channel"
        case "daily": "Daily"
        case "weekly": "Weekly"
        default: type.capitalized
        }
    }

    private func digestTypeColor(_ type: String) -> Color {
        switch type {
        case "channel": .blue
        case "daily": .purple
        case "weekly": .indigo
        default: .secondary
        }
    }

    private func sortMenu(_ vm: DigestViewModel) -> some View {
        Menu {
            ForEach(DigestViewModel.SortOrder.allCases, id: \.self) { order in
                Button {
                    vm.setSortOrder(order)
                } label: {
                    if vm.sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(vm.sortOrder.rawValue)")
    }

    private func tabLabel(_ tab: DigestTab, vm: DigestViewModel) -> String {
        switch tab {
        case .digests:
            // Slack digests + Gmail/Jira stream digests; meeting recordings
            // have no unread concept (DigestFeedEntry.isRead) so they never
            // contribute here. Sidebar digests badge stays Slack-only —
            // deliberately not touched (see the Task 11 brief).
            let n = vm.unreadDigestCount + vm.unreadStreamCount
            return n > 0 ? "\(tab.rawValue) (\(n))" : tab.rawValue
        case .decisions:
            let n = vm.unreadDecisionCount
            return n > 0 ? "\(tab.rawValue) (\(n))" : tab.rawValue
        }
    }
}

// MARK: - MeetingFeedDetailView

/// Inline recap for the `.meeting` case of the merged feed. There is no
/// existing cross-tab navigation target for a specific recording (unlike
/// digests/targets/tracks/briefings — see AppState's `pendingXID` family:
/// none of them address the Calendar tab's Events|Recordings split view down
/// to one recording), so this renders the recap content directly rather than
/// inventing one; the owner can open the Calendar tab separately to manage
/// the recording itself (delete, notes, transcript, chat).
private struct MeetingFeedDetailView: View {
    let recording: RecordingListItem
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var recapContent: MeetingRecap.Content?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let recapContent {
                    recapBody(recapContent)
                } else {
                    Text("No recap available for this recording yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(recording.eventTitle ?? recording.title)
        .task(id: recording.id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Meeting")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())

            Text(recording.eventTitle ?? recording.title)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)

            Spacer()

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

    @ViewBuilder
    private func recapBody(_ content: MeetingRecap.Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !content.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.headline)
                    Text(content.summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            bulletSection("Key Decisions", items: content.keyDecisions, color: .orange)
            bulletSection("Action Items", items: content.actionItems, color: .green)
            bulletSection("Open Questions", items: content.openQuestions, color: .blue)
        }
    }

    @ViewBuilder
    private func bulletSection(_ title: String, items: [String], color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(item)
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    /// Event recap wins, falling back to the recording's own summary — the
    /// `RecordingDetailView.load()` precedent (`recap?.parsed ??
    /// row?.parsedSummary`), minus the "from another source" provenance note
    /// (that nuance belongs to the Recordings tab's editing surface, not this
    /// read-only feed preview).
    private func load() async {
        guard let db = appState.databaseManager else {
            loaded = true
            return
        }
        let id = recording.id
        do {
            recapContent = try await db.dbPool.read { conn -> MeetingRecap.Content? in
                let row = try MeetingTranscriptQueries.fetch(conn, id: id)
                if let eventID = row?.eventID,
                   let recap = try MeetingRecapQueries.fetch(conn, eventID: eventID),
                   let parsed = recap.parsed {
                    return parsed
                }
                return row?.parsedSummary
            }
        } catch {
            // A read failure is not "no recap", but the pane has nothing
            // better to render either — keep the graceful nil fallback and
            // leave a trace (the `DigestWatcher` print convention) so the
            // failure isn't silent.
            print("[MeetingFeedDetailView] recap load error: \(error.localizedDescription)")
            recapContent = nil
        }
        loaded = true
    }
}
