import SwiftUI
import WatchtowerCore

/// Frame of the now-line marker row in the meetings scroll view's named
/// coordinate space; nil when no marker is rendered.
private struct NowLineFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Reference box for the marker's last published frame — mutating it does not
/// invalidate the view, unlike a plain `@State CGRect?`.
private final class NowLineFrameBox {
    var value: CGRect?
}

/// Unified master-detail "Meetings" screen for the Calendar tab: one
/// chronological list merging calendar events and recordings (an event with
/// recordings is one row; an ad-hoc or orphaned recording is its own row —
/// see `MeetingListBuilder`), with `MeetingDetailView` as the right pane.
struct CalendarEventsView: View {
    @Environment(AppState.self) private var appState
    private let google = GoogleConnectFlow.shared
    @State private var expandedAllDayDates: Set<Date> = []
    @State private var userNotes: String = ""
    @State private var selectedMeeting: MeetingSelection?
    @State private var recordings: [RecordingListItem] = []
    @State private var sections: [MeetingDaySection] = []
    /// Event id the meetings list should scroll to on next appearance/change —
    /// set by the recording→event deep link, consumed once.
    @State private var scrollTargetEventID: String?
    /// One-shot latch for the Today landing (`autoScrollToTodayOnce`): armed
    /// per screen life, consumed by the first scroll attempt that has
    /// non-empty `sections` — or by a deep link superseding it.
    @State private var didAutoScrollToToday = false
    @State private var showAddEmailAccountSheet = false
    @State private var showAddCalendarAccountSheet = false
    /// Why a connected calendar may show no events (#740) — re-read on a
    /// short loop while the tab is open, so it clears once the sync lands.
    @State private var syncHealth: CalendarSyncHealth = .ok
    @State private var syncHealthError: String?
    /// A failed Turn On / Start Sync restart — kept apart from
    /// `syncHealthError` because it is cleared by the daemon coming up (by
    /// any route: the app, the tray), not by a state change.
    @State private var restartError: String?
    /// The old daemon outlived the stop (`stopTimedOut`): one IS running, but
    /// it started before the change the restart was for, so its running does
    /// not clear the error — only a successful restart does.
    @State private var restartErrorOutlivesDaemon = false
    @State private var syncHealthReadFailed = false
    @State private var isRestartingSync = false
    /// Derived tri-state position of the now-line marker relative to the
    /// viewport (nil while no marker is rendered — no Today section). Storing
    /// the derived state instead of the raw frame means scroll ticks don't
    /// invalidate the whole non-lazy list — only actual visibility
    /// transitions do. Drives the floating "Now" button.
    @State private var nowLineVisibility: NowLine.Visibility?
    /// Last frame published by the marker row, boxed in a reference type so
    /// updating it never invalidates the view tree — it only feeds
    /// `updateNowLineVisibility` when either geometry input changes.
    @State private var lastNowLineFrame = NowLineFrameBox()

    /// True once ANY calendar source is connected — Google OAuth OR at least
    /// one healthy CalDAV/ICS account — so connecting only e.g. an iCloud
    /// calendar (without ever touching Google) unlocks the events UI too.
    private var hasCalendarSource: Bool {
        google.calendar.isConnected
            || (appState.calendarAccountsViewModel?.accounts.contains { $0.isOK } ?? false)
    }

    var body: some View {
        Group {
            if hasCalendarSource, !google.isRunning, let calVM = appState.calendarViewModel {
                meetingsSplitView(calVM)
            } else {
                notConnectedView
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshSyncHealth()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func refreshSyncHealth() async {
        // The shared connect state gates the meetings list itself: refresh it
        // too, so a Reconnect that succeeded leaves the not-connected screen.
        await google.calendar.checkStatusAsync()
        guard let db = appState.databaseManager else { return }
        do {
            let (accounts, counts) = try await db.dbPool.read { conn in
                (try GoogleAccountQueries.fetchAll(conn), try CalendarQueries.calendarCountsBySource(conn))
            }
            let daemonRunning = DaemonManager.checkActiveWorkspaceDaemonRunning()
            let health = CalendarSyncHealth.evaluate(
                accounts: accounts,
                hasCalDAVSource: appState.calendarAccountsViewModel?.accounts.contains { $0.isOK } ?? false,
                // An unreadable config.yaml says nothing about the switch —
                // never diagnose (and offer to "fix") a switch we cannot read.
                syncSwitchOn: !ConfigService().calendarSyncReadsOff,
                googleCalendarCount: counts.google,
                calDAVCalendarCount: counts.calDAV,
                daemonRunning: daemonRunning
            )
            if daemonRunning, !restartErrorOutlivesDaemon { restartError = nil }
            // An action's error belongs to the state it was raised in.
            if health != syncHealth { syncHealthError = nil }
            syncHealth = health
            syncHealthReadFailed = false
        } catch {
            // Keep the last known state; log once per failure streak, not
            // every 15 s.
            if !syncHealthReadFailed {
                NSLog("CalendarEventsView: calendar sync health read failed: %@", error.localizedDescription)
            }
            syncHealthReadFailed = true
        }
    }

    /// The fix for an install connected before the CLI turned the switch on
    /// itself: write `calendar.enabled`, then restart the daemon so it wires
    /// the calendar syncer and syncs it right at startup.
    private func turnOnCalendarSync() async {
        do {
            try ConfigService().turnOnCalendarSync()
        } catch {
            syncHealthError = "Couldn't turn calendar sync on: \(error.localizedDescription)"
            return
        }
        await restartSync()
    }

    /// Starts the daemon (or restarts it) and surfaces a failure in the banner.
    private func restartSync() async {
        isRestartingSync = true
        defer { isRestartingSync = false }
        // On the app's one start chain (launch, banner, Settings).
        let daemon = appState.daemonControl
        let failure = await appState.enqueueDaemonStart { () -> (any Error)? in
            do {
                try await daemon.restartWaiting()
                return nil
            } catch {
                return error
            }
        }.value
        if let error = failure {
            NSLog("CalendarEventsView: sync restart failed: %@", error.localizedDescription)
            restartError = "Couldn't restart the sync: \(error.localizedDescription)"
            // The app-wide banner says it too (and its Retry restarts).
            appState.daemonStartFailure = AppState.daemonRestartFailureText(error)
            if case DaemonRestartError.stopTimedOut = error {
                restartErrorOutlivesDaemon = true
            } else {
                restartErrorOutlivesDaemon = false
            }
        } else {
            restartError = nil
            restartErrorOutlivesDaemon = false
            appState.daemonStartFailure = nil
        }
        await refreshSyncHealth()
    }

    /// Resolves a `MeetingSelection` (row tap, deep link) to its
    /// `MeetingListEntry` in the currently built `sections` — nil once the
    /// entry has scrolled out of the window or was pruned (e.g. a stale
    /// deep-link target after a reload). Pure/static for direct unit testing.
    static func entry(for selection: MeetingSelection, in sections: [MeetingDaySection]) -> MeetingListEntry? {
        for section in sections {
            if let match = section.entries.first(where: { $0.id == selection }) {
                return match
            }
        }
        return nil
    }

    /// Selection resulting from a row tap: tapping the already-selected row
    /// deselects it (closing the detail pane), any other row selects it.
    static func toggledSelection(current: MeetingSelection?, tapped: MeetingSelection) -> MeetingSelection? {
        current == tapped ? nil : tapped
    }

    private func selectRow(_ tapped: MeetingSelection) {
        selectedMeeting = Self.toggledSelection(current: selectedMeeting, tapped: tapped)
    }

    /// Recording→event deep link ("Linked to:" header tap). The linked event
    /// may be outside the default today..+7d window in EITHER direction —
    /// sync retains ~24h back and calendar.sync_days_ahead is configurable —
    /// so first pin its day into the rendered window (synchronous reload),
    /// then select the event and scroll it into view.
    private func openLinkedEvent(_ link: CalendarQueries.EventLink, in vm: CalendarViewModel) {
        if let start = link.startDate {
            vm.ensureVisible(date: start)
        }
        // An all-day event renders inside a collapsed chip — expand its day
        // too, or the row would stay hidden.
        if let day = vm.dailyEvents.first(where: { day in
            day.events.contains { $0.id == link.id && $0.isAllDay }
        }) {
            expandedAllDayDates.insert(day.id)
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedMeeting = .event(link.id)
        }
        scrollTargetEventID = link.id
    }

    /// Home's Next meeting deep link (`AppState.navigateToCalendarEvent`):
    /// cleared on first sight, then opened as the recording→event link is.
    /// It supersedes the Today landing, as the scroll's own deep link does.
    private func openPendingEvent(in vm: CalendarViewModel) {
        guard let eventID = appState.pendingCalendarEventID else { return }
        appState.pendingCalendarEventID = nil
        guard let db = appState.databaseManager else {
            NSLog("CalendarEventsView: deep-linked event %@ dropped: no database", eventID)
            return
        }
        do {
            guard let link = try db.dbPool.read({ try CalendarQueries.fetchEventLink($0, id: eventID) }) else {
                NSLog("CalendarEventsView: deep-linked event %@ is gone", eventID)
                return
            }
            didAutoScrollToToday = true
            openLinkedEvent(link, in: vm)
        } catch {
            NSLog("CalendarEventsView: deep-linked event %@ read failed: %@", eventID, "\(error)")
        }
    }

    // MARK: - Split view

    private func meetingsSplitView(_ vm: CalendarViewModel) -> some View {
        HStack(spacing: 0) {
            meetingsList
                .frame(minWidth: 300, idealWidth: 350)

            if let selected = selectedMeeting, let entry = Self.entry(for: selected, in: sections) {
                Divider()
                MeetingDetailView(
                    entry: entry,
                    userNotes: $userNotes,
                    onDeleted: handleRecordingDeleted,
                    onChanged: loadRecordings,
                    onClose: { selectedMeeting = nil },
                    onOpenEvent: { link in openLinkedEvent(link, in: vm) }
                )
                // Recreates the pane per entry — the detail view's @State
                // (`selectedRecordingID`, `descriptionExpanded`) relies on
                // this wrapper for its reset-on-switch semantics.
                .id(entry.id)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedMeeting)
        .onAppear {
            vm.loadEvents()
            loadRecordings()
            // Explicit build, not left to the onChange handlers below:
            // `vm` is a shared, already-loaded `@Observable` (its `init`
            // eagerly calls `loadEvents()`), so `vm.loadEvents()` here can be
            // a same-value no-op that never fires `.onChange(of: vm.dailyEvents)`
            // — and a workspace with events but zero recordings ever made
            // would likewise never trigger `.onChange(of: recordings)`
            // (`[] == []`). Sections must exist on first appearance regardless.
            rebuildSections(vm)
            openPendingEvent(in: vm)
            appState.autoDownloadTranscriptionModel()
        }
        .onChange(of: appState.pendingCalendarEventID) { _, _ in openPendingEvent(in: vm) }
        // Keyed on the save counter, not on the recorder settling: with capture
        // decoupled from the queue, a transcript can land while another job is
        // still queued or a failed one lingers — `phase` never reaches `.idle`
        // then, and the new row would never appear.
        .onChange(of: appState.meetingRecorderCenter.savedTick) { _, _ in loadRecordings() }
        .onChange(of: vm.dailyEvents) { _, _ in rebuildSections(vm) }
        .onChange(of: recordings) { _, _ in rebuildSections(vm) }
    }

    private func handleRecordingDeleted() {
        selectedMeeting = nil
        loadRecordings()
    }

    private func loadRecordings() {
        guard let db = appState.databaseManager else { return }
        do {
            recordings = try db.dbPool.read { conn in
                try MeetingTranscriptQueries.fetchRecordingList(conn)
            }
        } catch {
            // Render-nothing on failure, but never silently: an empty list and
            // a failed read must be distinguishable in the logs.
            print("CalendarEventsView recordings load failed: \(error)")
        }
    }

    private func rebuildSections(_ vm: CalendarViewModel) {
        sections = MeetingListBuilder.build(
            days: vm.dailyEvents, recordings: recordings, now: Date(), calendar: .current)
    }

    // MARK: - Meetings List

    private var meetingsList: some View {
        // Header pinned OUTSIDE the scroll content: the Today landing scrolls
        // the list past its top, so an in-scroll header would hide the only
        // ad-hoc Record affordance until the user scrolls all the way back up.
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
            syncHealthBanner
            scrollableSections
        }
    }

    private var scrollableSections: some View {
        ScrollViewReader { proxy in
            // GeometryReader supplies the viewport height for the marker
            // visibility check — the app targets macOS 14, so the macOS 15+
            // onScrollGeometryChange APIs are off the table.
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sections) { section in
                            daySection(section)
                                .id(section.id)
                        }

                        if sections.isEmpty {
                            emptyState
                        }
                    }
                    .padding()
                }
                .coordinateSpace(name: Self.meetingsScrollSpace)
                .onPreferenceChange(NowLineFramePreferenceKey.self) { frame in
                    lastNowLineFrame.value = frame
                    updateNowLineVisibility(viewportHeight: viewport.size.height)
                }
                // The classification depends on TWO inputs; a height-only
                // resize keeps the marker frame byte-identical in the scroll
                // space, so the preference alone would go stale.
                .onChange(of: viewport.size.height) { _, height in
                    updateNowLineVisibility(viewportHeight: height)
                }
                .overlay(alignment: .bottom) {
                    jumpToNowButton(proxy: proxy)
                }
                // Deep-link scroll wins when a target is set (before this view
                // first appears); otherwise land on "Today" past the history days.
                .onAppear {
                    if scrollTargetEventID != nil {
                        // A deep link supersedes the Today landing for this
                        // appearance — consume the latch so the retrigger
                        // below can never fight the deep-link scroll.
                        didAutoScrollToToday = true
                        scrollToTargetIfNeeded(proxy)
                    } else {
                        autoScrollToTodayOnce(proxy)
                    }
                }
                // SwiftUI defines no order between this ScrollView's .onAppear
                // and the parent HStack's (which builds `sections`): on a
                // first render `sections` can still be empty here, so re-arm
                // the one-shot Today landing for the empty→populated
                // transition.
                .onChange(of: sections) { _, _ in autoScrollToTodayOnce(proxy) }
                .onChange(of: scrollTargetEventID) { _, _ in scrollToTargetIfNeeded(proxy) }
            }
        }
    }

    private func scrollToTargetIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = scrollTargetEventID else { return }
        scrollTargetEventID = nil
        // Same hazard as the Today landing below: for an out-of-window event
        // `openLinkedEvent` pins the day via a synchronous reload, so this
        // fires in the transaction that first materializes the target row —
        // its `.id` isn't laid out yet and `scrollTo` would silently no-op.
        // The guard/consume stays synchronous; only the scroll defers.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    /// One-shot Today landing: runs on the first non-empty `sections`,
    /// whether that happens before or after this view's `.onAppear`.
    private func autoScrollToTodayOnce(_ proxy: ScrollViewProxy) {
        guard !didAutoScrollToToday, !sections.isEmpty else { return }
        didAutoScrollToToday = true
        // The empty→populated `.onChange(of: sections)` fires in the same
        // transaction that first materializes the day rows and the now-line —
        // their `.id`s aren't laid out yet, and `scrollTo` against an
        // unregistered id is a silent no-op. Land after the layout commits.
        DispatchQueue.main.async { scrollToToday(proxy) }
    }

    /// With past days in the list, land on the now-line when today has a
    /// section (the marker always renders inside it), so the viewport opens
    /// at the current time instead of the morning's past meetings. Without a
    /// today section fall back to `todayScrollTarget`: the first future day,
    /// or the LAST section when the window holds only history.
    private func scrollToToday(_ proxy: ScrollViewProxy) {
        let today = Calendar.current.startOfDay(for: Date())
        switch Self.initialScrollTarget(in: sections, today: today) {
        case .nowLine:
            proxy.scrollTo(NowLine.nowLineID, anchor: .center)
        case .day(let target):
            proxy.scrollTo(target, anchor: .top)
        case nil:
            break
        }
    }

    /// Where the one-shot landing goes (pure — unit-tested directly, the
    /// `todayScrollTarget` pattern): the now-line when today has a section,
    /// else the `todayScrollTarget` fallback day, nil on an empty list.
    enum InitialScrollTarget: Equatable {
        case nowLine
        case day(Date)
    }

    static func initialScrollTarget(in sections: [MeetingDaySection], today: Date) -> InitialScrollTarget? {
        if sections.contains(where: { $0.id == today }) { return .nowLine }
        return todayScrollTarget(in: sections, today: today).map { .day($0) }
    }

    /// Pure target selection for the Today landing (testable without a view):
    /// the first section at/after `today`, else the last (most recent past)
    /// section — a window with no events ahead and nothing recorded today has
    /// no today-or-future section (`CalendarViewModel.loadEvents` emits only
    /// non-empty days), and resting at the natural list top would open on the
    /// OLDEST history day under the chronological ordering.
    static func todayScrollTarget(in sections: [MeetingDaySection], today: Date) -> Date? {
        sections.first { $0.id >= today }?.id ?? sections.last?.id
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.blue)
            Text("Calendar")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            MeetingRecordButton(eventID: nil, title: nil)
        }
    }

    // MARK: - Day Section

    private func daySection(_ section: MeetingDaySection) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(section.id)
        let isPast = section.id < cal.startOfDay(for: Date())
        let allDayEvents: [CalendarEvent] = section.entries.compactMap { entry in
            guard case let .event(event, _) = entry.kind, event.isAllDay else { return nil }
            return event
        }
        let timedEntries = section.entries.filter { entry in
            if case let .event(event, _) = entry.kind { return !event.isAllDay }
            return true
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text(section.label)
                .font(.headline)
                .foregroundStyle(isToday ? .primary : .secondary)

            if !allDayEvents.isEmpty {
                allDayChip(allDayEvents, date: section.id)
            }

            if isToday {
                // Only the Today section ticks: TimelineView recomputes the
                // marker's label and position once a minute.
                TimelineView(.everyMinute) { context in
                    timedRowsWithNowLine(timedEntries, now: context.date)
                }
            } else {
                ForEach(timedEntries) { entry in
                    entryRow(entry)
                }
            }
        }
        // Past days are browsable history, visually receded. Edge: a
        // cross-midnight meeting still running lands in a dimmed past
        // section WITH the green now-highlight — accepted cosmetic quirk.
        .opacity(isPast ? 0.55 : 1)
    }

    // MARK: - Now Line

    private static let meetingsScrollSpace = "meetings-scroll"

    private static let nowLineTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    /// Today's timed rows with the red now-line marker inserted at
    /// `NowLine.nowLineIndex` — before the first not-yet-started row, or
    /// after the last one when everything has started. Rendered from
    /// `NowLine.rows`, the single insertion site.
    private func timedRowsWithNowLine(_ entries: [MeetingListEntry], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(NowLine.rows(entries: entries, now: now)) { row in
                switch row {
                case .entry(let entry):
                    entryRow(entry)
                case .nowLine:
                    nowLineRow(now: now)
                }
            }
        }
    }

    private func nowLineRow(now: Date) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
            Text(Self.nowLineTimeFormatter.string(from: now))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.red)
            Rectangle()
                .fill(.red)
                .frame(height: 1.5)
        }
        // Publish the marker's frame in the scroll view's coordinate space so
        // the floating "Now" button knows when it is off-screen (preference
        // key instead of the macOS 15+ scroll-visibility APIs).
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: NowLineFramePreferenceKey.self,
                    value: geo.frame(in: .named(Self.meetingsScrollSpace))
                )
            }
        )
        .id(NowLine.nowLineID)
    }

    private func updateNowLineVisibility(viewportHeight: CGFloat) {
        let visibility = NowLine.visibility(
            frame: lastNowLineFrame.value, viewportHeight: viewportHeight
        )
        if visibility != nowLineVisibility {
            nowLineVisibility = visibility
        }
    }

    /// Floating jump-to-now capsule, shown only while the marker exists and
    /// sits outside the viewport.
    @ViewBuilder
    private func jumpToNowButton(proxy: ScrollViewProxy) -> some View {
        if let arrow = nowLineVisibility?.jumpArrowSymbol {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(NowLine.nowLineID, anchor: .center)
                }
            } label: {
                // Styling lives on the Label (the allDayChip pattern) so the
                // whole painted capsule is clickable with .buttonStyle(.plain).
                Label("Now", systemImage: arrow)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .padding(.bottom, 12)
        }
    }

    // MARK: - All-Day Chip

    private func allDayChip(_ events: [CalendarEvent], date: Date) -> some View {
        let isExpanded = expandedAllDayDates.contains(date)
        let previewTitles = events.prefix(3).map(\.title).joined(separator: " · ")
        let extra = events.count - min(3, events.count)
        let preview = extra > 0 ? "\(previewTitles) · +\(extra)" : previewTitles

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedAllDayDates.remove(date)
                    } else {
                        expandedAllDayDates.insert(date)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sun.horizon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(events.count) all-day")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(events.map(\.title).joined(separator: "\n"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events) { event in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                            Text(event.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.leading, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectRow(.event(event.id))
                        }
                        .id(event.id)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func entryRow(_ entry: MeetingListEntry) -> some View {
        switch entry.kind {
        case let .event(event, folded):
            HStack {
                CalendarEventRow(event: event, recordingCount: folded.count)
                    .contentShape(Rectangle())
                    .onTapGesture { selectRow(entry.id) }

                if event.conferenceLink != nil, event.endDate > Date() {
                    joinButton(event)
                }
            }
            .id(event.id)
        case let .recording(item):
            MeetingRecordingRow(item: item, isSelected: selectedMeeting == entry.id)
                .contentShape(Rectangle())
                .onTapGesture { selectRow(entry.id) }
                .id(item.id)
        }
    }

    // MARK: - Join Button

    /// Opens the event's conference link and (per the "Auto-record on join"
    /// setting) starts an event-linked recording via the shared
    /// `JoinMeetingAction`. Prominent while the meeting is imminent/ongoing.
    @ViewBuilder
    private func joinButton(_ event: CalendarEvent) -> some View {
        JoinButton(event: event,
                   center: appState.meetingRecorderCenter,
                   prominent: event.isUpcoming || event.isHappeningNow)
    }

    /// No calendar connected: the shared empty state (Connect → Settings),
    /// with the in-place Google / CalDAV connect options kept inside.
    static func notConnectedState<Options: View>(
        context: EmptyStateContext, @ViewBuilder connectOptions: () -> Options
    ) -> some View {
        TabEmptyState(.calendar, context: context, extra: connectOptions)
    }

    /// Nothing in the list: with synced events that is just nothing upcoming;
    /// before any event is synced, the shared empty state.
    static func noEventsState(context: EmptyStateContext) -> some View {
        ContentAwareEmptyState(.calendar, context: context) {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No upcoming events")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    // MARK: - Sync health

    @ViewBuilder
    private var syncHealthBanner: some View {
        switch syncHealth {
        case .ok, .awaitingFirstSync:
            // A failed restart can land on an otherwise healthy or waiting
            // state (calendars synced before, or an old daemon still up) —
            // it must still be seen, with the retry.
            if let restartError {
                healthBanner(icon: "exclamationmark.triangle", text: "The sync didn't restart.", error: restartError) {
                    syncButton("Restart Sync") { await restartSync() }
                }
            } else if syncHealth == .awaitingFirstSync {
                healthBanner(icon: nil, text: "Syncing your calendar — events appear within a minute.", error: nil) {
                    EmptyView()
                }
            }
        case .syncOff:
            healthBanner(
                icon: "exclamationmark.triangle",
                text: "Calendar sync is off — your Google Calendar is connected, but Watchtower isn't syncing it.",
                error: syncHealthError ?? restartError
            ) {
                syncButton("Turn On Calendar Sync") { await turnOnCalendarSync() }
            }
        case .accountError(let account):
            healthBanner(
                icon: "exclamationmark.triangle",
                text: accountErrorText(account),
                error: appState.googleAccountsViewModel?.error
            ) {
                reconnectButton(account)
            }
        case .daemonStopped:
            // The app-wide banner says the daemon isn't running (or why it
            // did not restart) and starts it: one message, one control.
            EmptyView()
        }
    }

    @ViewBuilder
    private func syncButton(_ title: String, action: @escaping () async -> Void) -> some View {
        if isRestartingSync {
            ProgressView().controlSize(.small)
        } else {
            Button(title) { Task { await action() } }
        }
    }

    private func healthBanner<Action: View>(
        icon: String?,
        text: String,
        error: String?,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                action()
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func accountErrorText(_ account: GoogleAccount) -> String {
        let reason = account.error.isEmpty ? "" : ": \(account.error)"
        return "Google Calendar for \(account.displayName) can't sync\(reason). Reconnect if it keeps failing."
    }

    @ViewBuilder
    private func reconnectButton(_ account: GoogleAccount) -> some View {
        if appState.googleAccountsViewModel?.isConnecting == true {
            ProgressView().controlSize(.small)
        } else {
            Button("Reconnect") {
                appState.googleAccountsViewModel?.relogin(account, daemonPolicy: appState.accountDaemonPolicy)
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        Self.noEventsState(context: appState.emptyStateContext)
    }

    private var notConnectedView: some View {
        Group {
            if case .accountError(let account) = syncHealth {
                accountErrorView(account)
            } else {
                Self.notConnectedState(context: appState.emptyStateContext) {
                    connectOptions
                }
            }
        }
        .onAppear {
            google.refresh()
            appState.calendarAccountsViewModel?.refresh()
        }
        .sheet(isPresented: $showAddEmailAccountSheet) {
            AddEmailAccountView()
                .environment(appState)
        }
        .sheet(isPresented: $showAddCalendarAccountSheet) {
            AddCalendarAccountView()
                .environment(appState)
        }
    }

    /// The Google account behind the calendar needs a reconnect: say so,
    /// with Reconnect first and the other connect options below.
    private func accountErrorView(_ account: GoogleAccount) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Google Calendar can't sync")
                .font(.headline)
            Text(accountErrorText(account))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            reconnectButton(account)
                .controlSize(.large)
            if let err = appState.googleAccountsViewModel?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Or connect another calendar:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            connectOptions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectOptions: some View {
        VStack(spacing: 14) {
            if google.isRunning {
                ProgressView("Connecting Google...")
                    .padding(.top, 4)
                Button("Cancel") {
                    google.cancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                // Two equally-visible paths — a barely-there caption link is
                // not discoverable enough for the primary alternative.
                Button {
                    google.includeGmail = false
                    google.includeCalendar = true
                    google.connect()
                } label: {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                        .frame(width: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)

                Button {
                    showAddCalendarAccountSheet = true
                } label: {
                    Label("Connect iCloud / CalDAV / ICS calendar", systemImage: "link.badge.plus")
                        .frame(width: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let err = google.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Add an IMAP or Outlook mailbox instead…") {
                showAddEmailAccountSheet = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
        }
    }
}
