import SwiftUI
import WatchtowerCore

/// The dialog of an agent session as a chat (`.sessionChat`): the owner
/// right in a tinted bubble, the agent left without one, Watchtower's own
/// lines marked "via Watchtower", subagents as cards opening in place (the
/// path bar leads back).
struct SessionChatView: View {
    @Environment(AppState.self) private var appState
    let vm: WorkbenchesViewModel
    let sessionID: Int64
    let projectID: Int64

    @StateObject private var store: SessionFeedStore
    /// The subagents opened in place; empty = the main feed.
    @State private var path = SessionChatPath()
    @FocusState private var subagentFocused: Bool
    /// Per pane, never shared across sessions: parsed text per entry, the
    /// built slice of a long chat, and which events show their body.
    @State private var markdown = SessionFeedMarkdownCache()
    @State private var window = SessionFeedWindow()
    @State private var expandedEvents: Set<String> = []
    @State private var follow = ChatFollowTrackerBox()
    @State private var loadingRowVisible = false
    private static var bottomID: String { "session-chat-bottom" }
    private static var scrollSpace: String { "session-chat-scroll" }

    init(vm: WorkbenchesViewModel, sessionID: Int64, projectID: Int64) {
        self.vm = vm
        self.sessionID = sessionID
        self.projectID = projectID
        // An autoclosure: the store and its CLI lookup are built once per
        // pane, not on every render of the parent.
        _store = StateObject(wrappedValue: SessionFeedStore(sessionID: sessionID, runner: ProcessCLIRunner.makeDefault()))
    }

    /// The agent works or has background subagents running: poll every 3 s.
    private var isActive: Bool {
        guard let session = vm.session(sessionID, projectID: projectID) else { return false }
        let kind = vm.sessionState(session).kind
        return kind == .working || kind == .background
    }

    private var stateKind: SessionSwitcherPresentation.State.Kind? {
        vm.session(sessionID, projectID: projectID).map { vm.sessionState($0).kind }
    }

    /// The session's composer (#711); nil without the app's `SessionControl`.
    private var workchat: WorkchatModel? { vm.workchat(sessionID: sessionID) }

    /// A live session that has not finished takes lines; a finished or
    /// stopped one keeps its history readable only.
    private var composerShown: Bool {
        guard let session = vm.session(sessionID, projectID: projectID) else { return false }
        let state = vm.sessionState(session)
        return state.live && state.kind != .finished
    }

    /// A known session that ended shows the finished line; an unknown one
    /// (the sessions not loaded yet) shows neither it nor the composer.
    private var finishedShown: Bool {
        vm.session(sessionID, projectID: projectID) != nil && !composerShown
    }

    /// The round button is Stop while the agent or its subagents work.
    private var working: Bool {
        vm.sessionStatuses[sessionID].map(SessionControl.isWorking) ?? false
    }

    /// The live line (Task 6): the agent's open step, Agents working or
    /// Thinking…, from the main feed's `activity`. The permission card
    /// replaces it while it shows.
    private var activityLine: WorkchatActivityPresenter.Line? {
        guard permission == nil else { return nil }
        return Self.activityLine(
            activity: store.activity, working: working, background: stateKind == .background,
            status: vm.sessionStatuses[sessionID],
            entries: store.entries,
            runningSubagents: store.entries.count { $0.kind == "subagent" && $0.subagent?.status == "running" })
    }

    static func activityLine(
        activity: SessionFeedActivity?,
        working: Bool,
        background: Bool,
        status: SessionAgentStatus?,
        entries: [SessionFeedEntry],
        runningSubagents: Int
    ) -> WorkchatActivityPresenter.Line? {
        let lastAgent = entries.last { $0.kind == "agent" }
        return WorkchatActivityPresenter.line(
            activity: activity, working: working, background: background, runningSubagents: runningSubagents,
            stateAt: SessionFeedEntry.parseDate(status?.at), lastAgentAt: lastAgent?.at)
    }

    /// The session's pending prompt, shown only while the session takes
    /// lines: a finished one's stale row is not answered from here.
    private var permission: SessionControl.PermissionPrompt? {
        composerShown ? workchat?.permission : nil
    }

    /// This session's open asks, oldest first; one leaves once answered.
    private var openAsks: [OwnerAsk] {
        (vm.asks.openAsks[projectID] ?? []).filter { $0.sessionID == sessionID }
    }

    /// A typed or copied line waits for the owner in the terminal.
    private func showInTerminal() {
        Task { await vm.showTerminalFromWorkchat(sessionID: sessionID, projectID: projectID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.runnerMissing {
                errorBar(WorkbenchesViewModel.cliMissingMessage, retry: false)
            } else if path.isRoot, let error = store.error {
                errorBar(error, retry: true)
            }
            if let subagent = path.stack.last {
                subagentScreen(subagent)
            } else if store.entries.isEmpty && (workchat?.outgoing.isEmpty ?? true) && permission == nil && openAsks.isEmpty {
                emptyState
            } else {
                feed
            }
            if path.isRoot && finishedShown {
                // No composer and no Stop once the session ended.
                Divider()
                Text("Session finished. The history stays readable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.cozy)
            } else if path.isRoot, composerShown, let workchat {
                WorkchatActivityLine(line: activityLine)
                Divider()
                // No card to carry it: a failed permission read shows here.
                if permission == nil, let error = workchat.permissionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.large)
                        .padding(.top, Spacing.compact)
                }
                WorkchatComposer(model: workchat, working: working)
            }
        }
        // Each hook write for the session reads its permission prompt again
        // (its hook writes the row and the state): keyed on the stamp
        // too, so a second prompt within one state poll is still read.
        .task(id: WorkchatModel.PermissionReadKey(vm.sessionStatuses[sessionID])) {
            await workchat?.refreshPermission()
        }
        // The feed shows a sent line: its bubble leaves.
        .onChange(of: store.entries) { _, entries in workchat?.reconcile(with: entries) }
        // The main feed is polled only while it is on screen: an open
        // subagent stops it, and back at the root it is read once.
        .task(id: MainFollowKey(state: stateKind, root: path.isRoot)) {
            guard path.isRoot else { return }
            await store.follow(isActive: { isActive }, isOnScreen: { vm.isTabOnScreen() })
        }
        // The app's visibility hub (#731): back on screen after a skipped
        // read, the feed is read at once. Bound to the pane's lifetime.
        .task(id: appState.uiVisibility.isOnScreen) {
            guard path.isRoot else { return }
            await store.screenChanged(appState.uiVisibility.isOnScreen)
        }
        .onChange(of: working) { _, nowWorking in
            if !nowWorking { store.clearActivity() }
        }
        .onChange(of: sessionID) { path = SessionChatPath() }
    }

    private struct MainFollowKey: Hashable {
        let state: SessionSwitcherPresentation.State.Kind?
        let root: Bool
    }

    /// Back on screen or a new session state: the open subagent is read again.
    private struct SubagentFollowKey: Hashable {
        let state: SessionSwitcherPresentation.State.Kind?
        let onScreen: Bool
    }

    /// One subagent in place of the feed: the path bar, its run, and the
    /// read-only line where the composer would be.
    private func subagentScreen(_ subagent: SessionFeedSubagent) -> some View {
        VStack(spacing: 0) {
            pathBar(subagent)
            Divider()
            SessionChatSubagentView(
                store: store,
                subagent: subagent,
                isActive: { isActive },
                isOnScreen: { vm.isTabOnScreen() },
                onOpenSubagent: { path.push($0) },
                liveLine: { activity, entries in
                    let lastAgent = entries.last { $0.kind == "agent" }
                    return WorkchatActivityPresenter.subagentLine(
                        activity: activity, sessionWorking: working, subagentStatus: subagent.status,
                        stateAt: SessionFeedEntry.parseDate(vm.sessionStatuses[sessionID]?.at),
                        lastAgentAt: lastAgent?.at)
                },
                followKey: SubagentFollowKey(state: stateKind, onScreen: appState.uiVisibility.isOnScreen)
            )
            .id(path.stack.map(\.toolUseID))
            Divider()
            Text("Subagents are read-only. Write to the agent in the main Workchat.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Spacing.cozy)
        }
        // Esc and ⌘[ pop one level while the pane has focus; it takes focus when
        // a subagent opens, so Esc works without another click.
        .focusable()
        .focusEffectDisabled()
        .focused($subagentFocused)
        // ⌘[ belongs to the menu's "Back to Workbenches", which runs this
        // first while this pane has focus.
        .focusedValue(\.sessionChatPop) { path.pop() }
        .onKeyPress(.escape) {
            path.pop()
            return .handled
        }
        .onAppear { subagentFocused = true }
    }

    /// **‹ Back**, then `Workchat › type › …`: each part opens its level.
    private func pathBar(_ subagent: SessionFeedSubagent) -> some View {
        HStack(spacing: Spacing.compact) {
            Button("‹ Back") { path.pop() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.small) {
                    Button("Workchat") { path.popTo(level: 0) }
                        .buttonStyle(.link)
                    ForEach(Array(path.stack.enumerated()), id: \.offset) { index, item in
                        Text("›").foregroundStyle(.tertiary)
                        let title = Self.title(item)
                        if index == path.stack.count - 1 {
                            Text(title).fontWeight(.semibold)
                        } else {
                            Button(title) { path.popTo(level: index + 1) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if let status = statusLabel(subagent) {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.compact)
    }

    private static func title(_ subagent: SessionFeedSubagent) -> String {
        subagent.type.isEmpty ? "Subagent" : subagent.type
    }

    /// The marker's status as it was when the subagent opened. "Running"
    /// only while the session is active: the main feed, which would update
    /// the marker, is not read while a subagent is open.
    private func statusLabel(_ subagent: SessionFeedSubagent) -> String? {
        switch subagent.status {
        case "running": isActive ? "Running" : nil
        case "finished": "Finished"
        default: nil
        }
    }

    /// The newest `window` of entries; the owner scrolling to the top grows
    /// it, and following the bottom works as in AI Chat (`ChatFollowTracker`).
    private var feed: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: Spacing.cozy) {
                        if window.hasEarlier(total: store.entries.count) {
                            loadingRow
                                .onAppear {
                                    loadingRowVisible = true
                                    if !loadEarlier(proxy: proxy) { fillIfShort(follow.tracker.lastMetrics) }
                                }
                                .onDisappear { loadingRowVisible = false }
                        }
                        ForEach(store.entries[window.range(total: store.entries.count)]) { entry in
                            row(entry).id(entry.id)
                        }
                        if let workchat {
                            ForEach(workchat.outgoing) { line in
                                WorkchatOutgoingBubble(
                                    line: line,
                                    working: working,
                                    holdsUntilIdle: workchat.holdsUntilIdle,
                                    onCancel: { workchat.cancel(line.id) },
                                    onShowTerminal: showInTerminal
                                )
                                .id(line.id)
                            }
                            if let permission {
                                WorkchatPermissionCard(model: workchat, prompt: permission, onShowTerminal: showInTerminal)
                                    .id("permission-\(permission.id)")
                            }
                        }
                        ForEach(openAsks) { ask in
                            WorkchatAskCard(ask: ask) { vm.asks.openDrawer(ask) }
                                .id("ask-\(ask.id)")
                        }
                        // The bottom margin: scrolling to it lands at the
                        // content's true bottom (the `ChatFeedView` rule).
                        Color.clear.frame(height: 14).id(Self.bottomID)
                    }
                    .padding([.top, .horizontal], Spacing.medium)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ChatContentFramePreferenceKey.self,
                                                   value: geo.frame(in: .named(Self.scrollSpace)))
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(ChatContentFramePreferenceKey.self) { frame in
                    guard let frame else { return }
                    measure(.init(contentTop: frame.minY, contentHeight: frame.height,
                                  viewportHeight: viewport.size.height), proxy: proxy)
                }
                // A height-only resize leaves the content frame unchanged in
                // the scroll space (the `ChatFeedView` rule).
                .onChange(of: viewport.size.height) { _, height in
                    guard let last = follow.tracker.lastMetrics else { return }
                    measure(.init(contentTop: last.contentTop, contentHeight: last.contentHeight,
                                  viewportHeight: height), proxy: proxy)
                }
            }
        }
    }

    private func row(_ entry: SessionFeedEntry) -> some View {
        SessionChatRow(entry: entry, blocks: markdown.blocks(for: entry),
                       expanded: expandedEvents.contains(entry.id),
                       onOpenSubagent: { entry.subagent.map { path.push($0) } },
                       onToggle: { toggleEvent(entry.id) })
            .equatable()
    }

    private var loadingRow: some View {
        HStack(spacing: Spacing.compact) {
            ProgressView().controlSize(.mini)
            Text("Loading earlier messages…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func toggleEvent(_ id: String) {
        if expandedEvents.contains(id) { expandedEvents.remove(id) } else { expandedEvents.insert(id) }
    }

    /// Grows the window by one step and keeps the entry that was at the top
    /// on screen. Only while the owner reads older text: a following view
    /// stays at the bottom (the loading row can lay out at open).
    /// Returns whether the window grew.
    @discardableResult
    private func loadEarlier(proxy: ScrollViewProxy) -> Bool {
        guard !window.following, let anchor = window.grow(entries: store.entries) else { return false }
        // After the grown rows lay out.
        DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        return true
    }

    /// Feeds one content measurement to the tracker, mirrors its follow bit
    /// into the window, and pulls a following view down when content grew.
    private func measure(_ current: ChatAutoScrollPolicy.Metrics, proxy: ScrollViewProxy) {
        guard current.viewportHeight > 0 else { return }
        let pull = follow.tracker.observeMeasurement(current)
        let following = follow.tracker.following
        if following != window.following {
            window.setFollowing(following, total: store.entries.count)
            // The loading row appeared before this scroll registered.
            if !following && loadingRowVisible { loadEarlier(proxy: proxy) }
        }
        if pull { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        fillIfShort(current)
    }

    /// Content shorter than the viewport keeps the loading row on screen, so
    /// its `onAppear` never fires again: grow from the measure path instead.
    /// Nothing scrolls, so no anchor is kept.
    private func fillIfShort(_ metrics: ChatAutoScrollPolicy.Metrics?) {
        guard let metrics,
              window.needsFill(total: store.entries.count, contentHeight: Double(metrics.contentHeight),
                               viewportHeight: Double(metrics.viewportHeight))
        else { return }
        _ = window.grow(entries: store.entries)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.error == nil && !store.runnerMissing {
            Text("No messages yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
        }
    }

    private func errorBar(_ message: String, retry: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 4)
            if retry {
                Button("Retry") { Task { await store.poller.refresh() } }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
    }
}
