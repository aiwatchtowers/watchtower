import SwiftUI
import AppKit

// MARK: - InboxFeedView

struct InboxFeedView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: InboxViewModel?
    @State private var feedbackItem: InboxItem?
    @State private var expandedItemID: InboxItem.ID?
    @State private var conversationCache: [InboxItem.ID: [InboxConversationMessage]] = [:]
    @State private var tab: Tab = .feed
    @State private var pendingInboxItem: InboxItem?
    @State private var inboxTargetPrefill: TargetPrefill?
    @State private var showCreateInboxTarget = false
    @State private var inboxPrefillError: String?
    @State private var isBuildingInboxPrefill = false

    enum Tab { case feed, learned }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if let msg = inboxPrefillError {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if tab == .feed {
                if let vm {
                    feedContent(vm)
                } else {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                learnedContent
            }
        }
        .onAppear {
            initViewModel()
            // Cross-process daemon writes don't fire GRDB ValueObservation,
            // so reload on every tab-appear to pick up items inserted while
            // the inbox tab was inactive.
            vm?.refresh()
        }
        .onChange(of: appState.isDBAvailable) { initViewModel() }
        .sheet(item: $feedbackItem) { item in
            if let vm {
                InboxFeedbackSheet(item: item) { rating, reason in
                    vm.submitFeedback(item, rating: rating, reason: reason)
                    feedbackItem = nil
                }
            }
        }
        .sheet(isPresented: $showCreateInboxTarget) {
            CreateTargetSheet(
                prefill: inboxTargetPrefill,
                onCreated: { newID in
                    guard let item = pendingInboxItem,
                          let db = appState.databaseManager else { return }
                    Task.detached {
                        try? await db.dbPool.write { dbConn in
                            try InboxQueries.linkTarget(dbConn, inboxID: item.id, targetID: newID)
                        }
                    }
                }
            )
        }
    }

    // MARK: - Toolbar (Tracks-style: title + count badge + filters)

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Inbox")
                    .font(.title2)
                    .fontWeight(.bold)

                if let vm, vm.unreadCount > 0 {
                    Text("\(vm.unreadCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                }

                Spacer()

                if tab == .feed, let vm {
                    Toggle("Unread only", isOn: Binding(
                        get: { vm.unreadOnly },
                        set: { vm.unreadOnly = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Hide items you've already read")
                }
            }

            Picker("", selection: $tab) {
                Text("Feed").tag(Tab.feed)
                Text("Learned").tag(Tab.learned)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Init

    private func initViewModel() {
        guard vm == nil, let db = appState.databaseManager else { return }
        let newVM = InboxViewModel(dbManager: db)
        vm = newVM
        newVM.startObserving()
    }

    // MARK: - Learned Tab

    @ViewBuilder
    private var learnedContent: some View {
        if let dbPool = appState.databaseManager?.dbPool {
            InboxLearnedRulesView(db: dbPool)
        } else {
            Text("Database unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Feed Content

    @ViewBuilder
    private func feedContent(_ vm: InboxViewModel) -> some View {
        if vm.pinnedItems.isEmpty && vm.feedItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !vm.pinnedItems.isEmpty {
                        sectionHeader("Pinned", count: vm.pinnedItems.count, color: .orange)
                        ForEach(vm.pinnedItems) { item in
                            inboxRow(item, vm: vm, size: .pinned)
                        }
                    }

                    ForEach(groupedByDay(vm.feedItems), id: \.day) { group in
                        sectionHeader(group.day, count: group.items.count, color: .secondary)
                        ForEach(group.items) { item in
                            inboxRow(item, vm: vm, size: cardSize(for: item))
                        }
                    }

                    if !vm.feedItems.isEmpty {
                        Button("Load more") { vm.loadMore() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Inbox is clear")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Mentions, DMs, and other items requiring your attention will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row Wrapper (background tint by state, like TracksListView.trackRow)

    private func inboxRow(_ item: InboxItem, vm: InboxViewModel, size: CardSize) -> some View {
        let isExpanded = expandedItemID == item.id
        let bgColor: Color = isExpanded
            ? Color.accentColor.opacity(0.12)
            : item.isUnread
                ? Color.blue.opacity(0.06)
                : Color.clear

        return InboxCardView(
            item: item,
            size: size,
            senderName: vm.senderName(for: item),
            userNames: vm.senderNames,
            channelName: vm.channelName(for: item),
            isExpanded: isExpanded,
            conversation: conversationCache[item.id] ?? [],
            conversationLoaded: conversationCache[item.id] != nil,
            slackURL: vm.slackMessageURL(for: item),
            onToggle: { toggleExpansion(item, vm: vm) },
            onSnooze: { option in snoozeItem(item, option: option, vm: vm) },
            onDismiss: { vm.dismiss(item) },
            onCreateTask: { openCreateTargetForInbox(item) },
            onMarkRead: { vm.markRead(item) },
            onFeedback: { rating, _ in
                if rating == -1 {
                    feedbackItem = item
                } else {
                    vm.submitFeedback(item, rating: rating, reason: "")
                }
            }
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            size == .pinned
                ? RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(pinnedStrokeColor(item), lineWidth: 1)
                : nil
        )
        .padding(.horizontal, 4)
    }

    private func pinnedStrokeColor(_ item: InboxItem) -> Color {
        switch item.priority {
        case "high":   return .red.opacity(0.5)
        case "medium": return .orange.opacity(0.5)
        default:       return .secondary.opacity(0.3)
        }
    }

    // MARK: - Section Header (matches TracksListView.sectionHeader)

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private func cardSize(for item: InboxItem) -> CardSize {
        item.itemClass == .ambient ? .compact : .medium
    }

    private func toggleExpansion(_ item: InboxItem, vm: InboxViewModel) {
        if expandedItemID == item.id {
            expandedItemID = nil
            return
        }
        // Lazy-load the live conversation on first expand; cache so collapsing and
        // re-expanding doesn't re-hit the DB. Cross-process daemon writes won't
        // refresh this cache — that's fine; the snippet/context fallback covers
        // the gap until the user expands again after a sync.
        if conversationCache[item.id] == nil {
            conversationCache[item.id] = vm.loadConversation(for: item)
        }
        vm.markSeen(item)
        expandedItemID = item.id
    }

    private func snoozeItem(_ item: InboxItem, option: InboxCardView.SnoozeOption, vm: InboxViewModel) {
        let until: String
        let cal = Calendar.current
        let now = Date()
        switch option {
        case .oneHour:
            until = iso8601String(cal.date(byAdding: .hour, value: 1, to: now) ?? now)
        case .tillTomorrow:
            let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
            until = iso8601String(tomorrow)
        case .tillMonday:
            var comps = DateComponents()
            comps.weekday = 2 // Monday
            let monday = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now
            until = iso8601String(cal.startOfDay(for: monday))
        }
        vm.snooze(item, until: until)
    }

    private func iso8601String(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private func openCreateTargetForInbox(_ item: InboxItem) {
        guard let db = appState.databaseManager else {
            inboxPrefillError = "Database not available"
            return
        }
        Task { @MainActor in
            isBuildingInboxPrefill = true
            defer { isBuildingInboxPrefill = false }
            do {
                let pf = try await TargetPrefillBuilder.fromInbox(item, db: db)
                inboxTargetPrefill = pf
                pendingInboxItem = item
                inboxPrefillError = nil
                showCreateInboxTarget = true
            } catch {
                inboxPrefillError = "Failed to prepare prefill: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Day Grouping

    private struct DayGroup {
        let day: String
        let items: [InboxItem]
    }

    private func groupedByDay(_ items: [InboxItem]) -> [DayGroup] {
        guard !items.isEmpty else { return [] }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let weekStart = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart

        var buckets: [(key: String, order: Int, items: [InboxItem])] = []
        var bucketIndex: [String: Int] = [:]

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        for item in items {
            let date = item.messageDate
            let label: String
            if date >= todayStart {
                label = "Today"
            } else if date >= yesterdayStart {
                label = "Yesterday"
            } else if date >= weekStart {
                label = "Earlier this week"
            } else {
                label = dateFormatter.string(from: cal.startOfDay(for: date))
            }

            if let idx = bucketIndex[label] {
                buckets[idx].items.append(item)
            } else {
                let order: Int
                switch label {
                case "Today":              order = 0
                case "Yesterday":          order = 1
                case "Earlier this week":  order = 2
                default:                   order = 3
                }
                bucketIndex[label] = buckets.count
                buckets.append((key: label, order: order, items: [item]))
            }
        }

        return buckets
            .sorted { $0.order < $1.order }
            .map { DayGroup(day: $0.key, items: $0.items) }
    }
}
