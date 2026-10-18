import SwiftUI
import WatchtowerCore

/// The dialog of an agent session as a chat (`.sessionChat`): the owner
/// right in a tinted bubble, the agent left without one, Watchtower's own
/// lines marked "via Watchtower", subagents as cards opening a sheet.
struct SessionChatView: View {
    @Environment(AppState.self) private var appState
    let vm: WorkbenchesViewModel
    let sessionID: Int64
    let projectID: Int64

    @StateObject private var store: SessionFeedStore
    @State private var openedSubagent: SessionFeedEntry?
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

    var body: some View {
        VStack(spacing: 0) {
            if store.runnerMissing {
                errorBar(WorkbenchesViewModel.cliMissingMessage, retry: false)
            } else if let error = store.error {
                errorBar(error, retry: true)
            }
            if store.entries.isEmpty {
                emptyState
            } else {
                feed
            }
        }
        .task(id: stateKind) {
            await store.follow(isActive: { isActive }, isOnScreen: { vm.isTabOnScreen() })
        }
        // The app's visibility hub (#731): back on screen after a skipped
        // read, the feed is read at once. Bound to the pane's lifetime.
        .task(id: appState.uiVisibility.isOnScreen) {
            await store.screenChanged(appState.uiVisibility.isOnScreen)
        }
        .sheet(item: $openedSubagent) { entry in
            SessionChatSubagentSheet(store: store, entry: entry)
        }
    }

    /// The newest `window` of entries; the owner scrolling to the top grows
    /// it, and following the bottom works as in AI Chat (`ChatFollowTracker`).
    private var feed: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if window.hasEarlier(total: store.entries.count) {
                            loadingRow
                                .onAppear {
                                    loadingRowVisible = true
                                    loadEarlier(proxy: proxy)
                                }
                                .onDisappear { loadingRowVisible = false }
                        }
                        ForEach(store.entries[window.range(total: store.entries.count)]) { entry in
                            row(entry).id(entry.id)
                        }
                        // The bottom margin: scrolling to it lands at the
                        // content's true bottom (the `ChatFeedView` rule).
                        Color.clear.frame(height: 14).id(Self.bottomID)
                    }
                    .padding([.top, .horizontal], 14)
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
                       onOpenSubagent: { openedSubagent = entry },
                       onToggle: { toggleEvent(entry.id) })
            .equatable()
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
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
    private func loadEarlier(proxy: ScrollViewProxy) {
        guard !window.following, let anchor = window.grow(entries: store.entries) else { return }
        // After the grown rows lay out.
        DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
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
