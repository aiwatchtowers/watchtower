import Foundation

/// The Workchat's quiet "agent finished" row (spec 2026-11-24-workchat-polish §3, D4): a task notification of Claude
/// Code — an agent or a background command finished — as a status glyph, the agent's name and one meta line
/// (`finished · 9 tools · 43.5k tokens · 1m 29s`); expanded, the result and the ids. Claude Code's boilerplate never
/// shows: the Go feed already dropped it from `result`.
package struct AgentFinishedPresentation: Equatable, Sendable {
    /// The glyph's colour, through the design kit's `Tone` in the view.
    package enum Tone: Equatable, Sendable { case success, failure, neutral }

    package static let resultLabel = "RESULT"
    package static let openOutputTitle = "Open output"
    package static let detailsTitle = "Details"
    /// The title of a notice whose summary names no agent.
    package static let untitled = "Agent"
    package static let commandTitle = "Background command"

    /// The agent's name (`#N` refs in it are coloured by the view, C8), or "Background command · <name>".
    package let title: String
    package let meta: String
    package let tone: Tone
    /// An SF Symbol name.
    package let glyph: String
    /// A background command: the row is caption-sized, its meta on the title's line.
    package let isCommand: Bool
    /// The agent's report; nil when there is none to show.
    package let result: String?
    /// The task and tool-use ids, cut short (`task aaea0001bcde… · toolu_01abcd…`); "" when there are none.
    package let details: String

    package init(task: SessionFeedTask, fallbackTitle: String) {
        isCommand = task.kind == "command"
        let name = Self.quotedName(task.summary)
        if isCommand {
            title = name.map { "\(Self.commandTitle) · \($0)" } ?? Self.commandTitle
        } else {
            title = name ?? [fallbackTitle, task.summary].first { !$0.isEmpty } ?? Self.untitled
        }
        if task.status == "failed" || (task.exitCode ?? 0) != 0 {
            tone = .failure
        } else if task.status == "killed" || task.status == "stopped" {
            tone = .neutral
        } else {
            tone = .success
        }
        glyph = switch tone {
        case .success: "checkmark"
        case .failure: "xmark"
        case .neutral: "stop"
        }
        meta = Self.meta(task, isCommand: isCommand)
        let report = task.result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = report.isEmpty ? nil : report
        details = [task.taskID.isEmpty ? nil : "task \(Self.cut(task.taskID))",
                   task.toolUseID.isEmpty ? nil : Self.cut(task.toolUseID)]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// Whether Open output shows `path` in the read-only viewer: only a file under the session's own Claude Code temp
    /// dir (`/tmp/claude-<uid>/<project>/<session id>/…`, `/private/tmp` too). Anything else is revealed in Finder.
    /// Lexical: a `.` or `..` component never counts as inside.
    package static func outputOpensInViewer(_ path: String, claudeSessionID: String?, uid: uid_t = getuid()) -> Bool {
        guard let claudeSessionID, !claudeSessionID.isEmpty, path.hasPrefix("/") else { return false }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        if parts.first == "private" { parts.removeFirst() }
        return parts.count >= 5 && parts[0] == "tmp" && parts[1] == "claude-\(uid)" && parts[3] == claudeSessionID
    }

    /// The text between the summary's first and last double quote (`Agent "Verify review #1" finished`).
    private static func quotedName(_ summary: String) -> String? {
        guard let open = summary.firstIndex(of: "\""), let close = summary.lastIndex(of: "\""), open < close else {
            return nil
        }
        let name = summary[summary.index(after: open) ..< close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func meta(_ task: SessionFeedTask, isCommand: Bool) -> String {
        var parts: [String] = []
        if isCommand, let exitCode = task.exitCode {
            parts.append("exit \(exitCode)")
        } else {
            parts.append(statusWord(task.status))
        }
        if !isCommand {
            if task.toolUses > 0 { parts.append(task.toolUses == 1 ? "1 tool" : "\(task.toolUses) tools") }
            if task.tokens > 0 { parts.append("\(compact(task.tokens)) tokens") }
        }
        if task.durationMS > 0 { parts.append(duration(ms: task.durationMS)) }
        return parts.joined(separator: " · ")
    }

    private static func statusWord(_ status: String) -> String {
        switch status {
        case "", "completed": "finished"
        case "killed", "stopped": "stopped"
        default: status
        }
    }

    /// 850, 1.2k, 43.5k, 1k, 1.3M.
    private static func compact(_ n: Int) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if n < 1000 { return "\(n)" }
        if n < 999_950 { return short(Double(n) / 1000, "k") }
        return short(Double(n) / 1_000_000, "M")
    }

    /// <1s, 12s, 1m 29s, 1h 2m — to the nearest second.
    private static func duration(ms: Int) -> String {
        let seconds = Int((Double(ms) / 1000).rounded())
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// An id cut to 12 characters and "…".
    private static func cut(_ id: String) -> String {
        id.count > 12 ? id.prefix(12) + "…" : id
    }
}
