import SwiftUI
import WatchtowerCore

/// A subagent's run opened in place in the session chat pane: the task it
/// was given, what it said on the way and its final report. Read when it
/// opens; while its marker says `running` and the session is active, read
/// again every 3 s through the store's one-CLI-at-a-time rule, each time with
/// the main feed, which holds the marker (its status is read there, not from
/// the copy opened).
struct SessionChatSubagentView: View {
    let store: SessionFeedStore
    let subagent: SessionFeedSubagent
    let parentToolUseID: String?
    /// The subagent's status in the main feed's current markers.
    let status: () -> String
    /// The session works or has background subagents running.
    let isActive: () -> Bool
    let isOnScreen: () -> Bool
    let onOpenSubagent: (SessionFeedSubagent) -> Void
    /// The subagent's own live line from its activity and entries; nil = none.
    let liveLine: (SessionFeedActivity?, [SessionFeedEntry]) -> WorkchatActivityPresenter.Line?
    /// Restarts the follow: the session's state or the screen changed.
    let followKey: AnyHashable

    @State private var entries: [SessionFeedEntry] = []
    @State private var activity: SessionFeedActivity?
    @State private var observedStatus: String?
    @State private var live: SessionFeedLive?
    @State private var liveError: String?
    @State private var liveLoaded = false
    @State private var refreshID = UUID()
    @State private var loading = true
    @State private var error: String?
    @State private var markdown = SessionFeedMarkdownCache()
    @State private var expandedEvents: Set<String> = []

    private var currentStatus: String {
        observedStatus ?? SessionSubagentLifecycle.status(parentStatus: status(), snapshot: live, error: liveError, now: .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            // Always the row, empty or not: the run does not jump.
            WorkchatLiveLine(snapshot: live, error: liveError, loaded: liveLoaded,
                             working: currentStatus != "finished" && isActive(), stateAt: nil,
                             onRetry: { refreshID = UUID() }, onOpenAgent: onOpenSubagent)
        }
            .task(id: SessionSubagentFollowKey(follow: followKey, retry: refreshID, parentToolUseID: parentToolUseID)) {
                await store.followSubagent(
                    subagent.toolUseID,
                    readsMainFeed: true,
                    parentToolUseID: parentToolUseID,
                    isSessionActive: isActive,
                    isRunning: { currentStatus == "running" && isActive() },
                    isOnScreen: isOnScreen,
                    onEntries: {
                        entries = $0
                        loading = false
                    },
                    onActivity: { activity = $0 },
                    onLive: {
                        if let snapshot = $0 { live = snapshot }
                        liveError = $1; liveLoaded = true
                    },
                    onStatus: { next in
                        if next == "running", observedStatus == "finished" {
                            live = nil; liveLoaded = false; liveError = nil
                        }
                        observedStatus = next
                    },
                    onError: {
                        error = $0
                        if $0 != nil { loading = false }
                    }
                )
                // The follow ended (finished or stopped): no stale step.
                activity = nil
                // Keep the completed snapshot as lifecycle evidence: dropping it
                // would resurrect the initially pushed `running` marker.
                if !isActive() { live = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, entries.isEmpty {
            Text(error).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text("Nothing recorded for this subagent").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                        if let heading = heading(index) {
                            Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        SessionChatRow(entry: item, blocks: markdown.blocks(for: item),
                                       expanded: expandedEvents.contains(item.id),
                                       onOpenSubagent: { item.subagent.map(onOpenSubagent) },
                                       onToggle: { toggleEvent(item.id) })
                            .equatable()
                    }
                }
                .padding(Spacing.medium)
            }
        }
    }

    /// The first owner line is the task given; the last agent line of a run
    /// with more than one is its report.
    private func heading(_ index: Int) -> String? {
        let item = entries[index]
        if index == 0, item.kind == "owner" { return "Task" }
        let agents = entries.filter { $0.kind == "agent" }
        if agents.count > 1, item.id == agents.last?.id { return "Report" }
        return nil
    }

    private func toggleEvent(_ id: String) {
        if expandedEvents.contains(id) { expandedEvents.remove(id) } else { expandedEvents.insert(id) }
    }
}
