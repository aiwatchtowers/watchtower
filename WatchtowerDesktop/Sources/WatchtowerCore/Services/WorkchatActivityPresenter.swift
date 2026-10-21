import Foundation

/// What the live line under the Workchat feed says (pure). The line is never
/// an entry: it shows the agent's open tool call, "Agents working" or
/// "Thinking…", and nothing while the agent is idle.
package enum WorkchatActivityPresenter {
    package struct Line: Equatable {
        package let symbol: String
        package let text: String
        /// The timer counts from here; nil = no timer.
        package let since: Date?
    }

    /// nil = no line. `working`: `SessionControl.isWorking`; `background`: the
    /// state kind is Agents working; `stateAt`: the status stamp (Thinking…
    /// counts from it); `lastAgentAt`: the newest agent entry's `at`.
    package static func line(
        activity: SessionFeedActivity?,
        working: Bool,
        background: Bool,
        runningSubagents: Int,
        stateAt: Date?,
        lastAgentAt: Date?
    ) -> Line? {
        guard working else { return nil }
        if let activity, lastAgentAt == nil || startedAfter(activity, lastAgentAt) {
            let more = activity.more > 0 ? " · \(activity.more) more" : ""
            return Line(symbol: symbol(for: activity.tool), text: activity.summary + more, since: activity.startedAt)
        }
        if background {
            let text = runningSubagents > 0 ? "Agents working · \(runningSubagents)" : "Agents working"
            return Line(symbol: "person.2", text: text, since: stateAt)
        }
        return Line(symbol: "ellipsis", text: "Thinking…", since: stateAt)
    }

    /// An activity without a start time cannot be older than the text.
    private static func startedAfter(_ activity: SessionFeedActivity, _ lastAgentAt: Date?) -> Bool {
        guard let started = activity.startedAt, let lastAgentAt else { return true }
        return lastAgentAt < started
    }

    package static func symbol(for tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "Agent", "Task": "person.2"
        case "WebFetch", "WebSearch": "globe"
        default: tool.hasPrefix("mcp__") ? "powerplug" : "gearshape"
        }
    }
}
