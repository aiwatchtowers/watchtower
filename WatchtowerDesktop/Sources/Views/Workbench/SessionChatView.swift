import ChatUI
import ChatWire
import SwiftUI
import WatchtowerCore
import WatchtowerChatText

/// The dialog of an agent session as a chat (`.sessionChat`): the owner
/// right in a tinted bubble, the agent left without one, Watchtower's own
/// lines marked "via Watchtower". Subagents live in the live line's 👥 list
/// (Working and Done) and open in place (the path bar leads back).
struct SessionChatView: View {
    @Environment(AppState.self) private var appState
    let vm: WorkbenchesViewModel
    let sessionID: Int64
    let projectID: Int64
    /// Each new value puts the keyboard in the composer (Branch review's Ask agent).
    var composerFocus: UUID?
    /// The composer takes the keyboard as it is made.
    var composerAutoFocus = false

    @StateObject private var store: SessionFeedStore
    /// The subagents opened in place; empty = the main feed.
    @State private var path = SessionChatPath()
    @FocusState private var subagentFocused: Bool
    /// Per pane, never shared across sessions: parsed text per entry, the
    /// built slice of a long chat, and which events show their body.
    @State private var markdown = SessionFeedMarkdownCache()
    @State private var window = SessionFeedWindow()
    @State private var expandedEvents: Set<String> = []
    /// The entry that was at the top before earlier messages loaded: the feed keeps it in view, then lets it go.
    @State private var earlierAnchor: Int64?
    /// An artifact card opened from the feed.
    @State private var artifact: ChatArtifactContent?

    init(
        vm: WorkbenchesViewModel,
        sessionID: Int64,
        projectID: Int64,
        composerFocus: UUID? = nil,
        composerAutoFocus: Bool = false
    ) {
        self.vm = vm
        self.sessionID = sessionID
        self.projectID = projectID
        self.composerFocus = composerFocus
        self.composerAutoFocus = composerAutoFocus
        // An autoclosure: the store and its CLI lookup are built once per
        // pane, not on every render of the parent.
        _store = StateObject(wrappedValue: SessionFeedStore(sessionID: sessionID, runner: ProcessCLIRunner.makeDefault()))
    }

    /// The agent works or has background subagents running: poll every 3 s.
    private var isActive: Bool {
        guard let session = vm.session(sessionID, projectID: projectID) else { return false }
        return WorkchatLivePresentation.busy(vm.sessionState(session))
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

    /// The line where the composer would be once it is gone: a kind this
    /// build does not know says so (never the finished line, A7b); a known
    /// session that ended keeps its history readable; nil otherwise.
    static func endedLine(kind: TerminalSession.Kind?, finishedShown: Bool) -> String? {
        if let unsupported = kind?.unsupportedMessage { return unsupported }
        return finishedShown ? finishedLine : nil
    }

    static let finishedLine = "Session finished. The history stays readable."

    /// The round button is Stop while the agent or its subagents work.
    private var working: Bool {
        vm.sessionStatuses[sessionID].map(SessionControl.isWorking) ?? false
    }

    /// Busy for the live line and the 👥 list: working, background agents, or
    /// waiting on an approval (the live snapshot stays read meanwhile).
    private var busy: Bool {
        WorkchatLivePresentation.busy(vm.sessionStatuses[sessionID]?.state)
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
            runningSubagents: store.subagents.count { $0.subagent?.status == "running" })
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
            } else if dialogEntries.isEmpty && (workchat?.outgoing.isEmpty ?? true) && permission == nil && openAsks.isEmpty {
                emptyState
            } else {
                feed
            }
            let ended = path.isRoot ? Self.endedLine(kind: vm.session(sessionID, projectID: projectID)?.kind,
                                                     finishedShown: finishedShown) : nil
            if let ended {
                // No composer and no Stop once the session ended, or for a
                // kind this build does not know (A7b).
                Divider()
                Text(ended)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.cozy)
                    .padding(.bottom, done.isEmpty ? Spacing.cozy : .zero)
            }
            // One live line for both states, so an open 👥 list survives the
            // session ending; under the ended line it stays while there are
            // finished agents to list.
            if path.isRoot, ended == nil ? composerShown && workchat != nil : !done.isEmpty {
                liveLine(working: ended == nil && busy)
                    .padding(.bottom, ended == nil ? .zero : Spacing.small)
            }
            if path.isRoot, ended == nil, composerShown, let workchat {
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
                WorkchatComposer(model: workchat, working: working, autoFocus: composerAutoFocus,
                                 focusRequest: composerFocus)
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
        // Only a session that stops being busy drops its step: an approval
        // prompt keeps the snapshot (its background agents still run).
        .onChange(of: busy) { _, nowBusy in
            if !nowBusy { store.clearActivity() }
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

    private func currentSubagentStatus(_ subagent: SessionFeedSubagent) -> String {
        store.live?.agents.first { $0.id == subagent.toolUseID }?.ref.status
            ?? SessionFeedSubagent.currentStatus(of: subagent, in: store.subagents)
    }

    /// The entries the feed draws: the subagent markers live in the 👥 list.
    private var dialogEntries: [SessionFeedEntry] { WorkchatFeedAdapter.dialog(store.entries) }

    /// The tab's finished subagents, the 👥 list's Done.
    private var done: [SessionFeedSubagent] { WorkchatLivePresentation.done(from: store.subagents) }

    /// The caption row over the composer (or under the ended line): the agent's
    /// step and the 👥 list.
    private func liveLine(working: Bool) -> some View {
        WorkchatLiveLine(snapshot: store.live, error: store.liveError,
                         loaded: store.liveLoaded, working: working,
                         // An approval (its card, or the state before the card is read) hides the step only.
                         activityHidden: permission != nil || !self.working,
                         stateAt: SessionFeedEntry.parseDate(vm.sessionStatuses[sessionID]?.at),
                         done: done, paneKey: "session-\(sessionID)", memory: vm.paneMemory,
                         feedLoaded: store.feedLoaded, feedError: store.error,
                         onRetry: { Task { await store.poller.refresh() } },
                         onRetryList: { Task { await store.poller.refresh() } },
                         onOpenAgent: { path.push($0) })
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
                parentToolUseID: path.stack.dropLast().last?.toolUseID,
                paneKey: "session-\(sessionID)/\(subagent.toolUseID)",
                memory: vm.paneMemory,
                status: { currentSubagentStatus(subagent) },
                isActive: { isActive },
                isOnScreen: { vm.isTabOnScreen() },
                onOpenSubagent: { path.push($0) },
                liveLine: { activity, entries in
                    let lastAgent = entries.last { $0.kind == "agent" }
                    return WorkchatActivityPresenter.subagentLine(
                        activity: activity, sessionWorking: working,
                        subagentStatus: currentSubagentStatus(subagent),
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

    /// The newest `window` of entries on ChatUI's feed (`WorkchatFeed`); "Load earlier messages" grows it, and the
    /// feed follows the bottom as in AI Chat. The lines on their way, the permission card and the open asks follow
    /// the entries.
    private var feed: some View {
        let entries = dialogEntries
        let total = entries.count
        let shown = Array(entries[window.range(total: total)])
        var workchatFeed = WorkchatFeed(entries: shown, markdown: markdown, expandedEvents: expandedEvents,
                                        onToggle: toggleEvent)
        // A question card's answers go to the agent as the owner's next line while the session takes lines.
        if composerShown, let workchat {
            workchatFeed.onAnswer = { text in Task { await workchat.sendLine(text) } }
        }
        workchatFeed.isWorking = working
        workchatFeed.answerPending = !(workchat?.outgoing.isEmpty ?? true)
        workchatFeed.onOpenArtifact = { artifact = $0 }
        var context = workchatFeed.context()
        context.hasEarlier = window.hasEarlier(total: total)
        context.rowActions.loadEarlier = loadEarlier
        context.focusMessageID = earlierAnchor
        var follow = ChatFeedFollow(conversationID: sessionID)
        follow.anchorsBottom = true
        follow.loadsEarlierAtTop = true
        follow.onFollowingChange = followingChanged
        follow.onFocusApplied = { earlierAnchor = nil }
        context.follow = follow
        context.footer = AnyView(pending)
        return ChatUI.ChatFeedView(messages: workchatFeed.messages, context: context)
            .macChatStyle(hooks: .app, look: .workchat)
            .embeddedArtifactSheet($artifact)
    }

    /// After the entries: the lines on their way, the permission card and this session's open asks.
    @ViewBuilder private var pending: some View {
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
    }

    private func toggleEvent(_ id: String) {
        if expandedEvents.contains(id) { expandedEvents.remove(id) } else { expandedEvents.insert(id) }
    }

    /// The owner scrolled up (the window keeps what they read) or back to the newest entries (the window lets its
    /// pin go and shrinks to the newest again).
    private func followingChanged(_ following: Bool) {
        if window.followingChanged(following, total: dialogEntries.count) { earlierAnchor = nil }
    }

    private func loadEarlier() {
        if let anchor = window.loadEarlier(entries: dialogEntries) { earlierAnchor = anchor }
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

extension SessionFeedWindow {
    /// The feed's follow bit: scrolling up pins what the owner reads; back at the newest entries the pin goes and the
    /// window shrinks to the newest again. True when the feed follows (its scroll anchor can go).
    mutating func followingChanged(_ following: Bool, total: Int) -> Bool {
        setFollowing(following, total: total)
        return following
    }

    /// Grows the window by one step: while the owner reads older text, the message id of the entry that was at the
    /// top, to keep in view; a following window (content shorter than the pane) just grows. Nil when nothing grew or
    /// nothing needs keeping.
    mutating func loadEarlier(entries: [SessionFeedEntry]) -> Int64? {
        guard hasEarlier(total: entries.count) else { return nil }
        let anchor = grow(entries: entries)
        return following ? nil : anchor.map(WorkchatFeedAdapter.messageID)
    }
}
