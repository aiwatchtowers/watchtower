import Foundation

/// The workbench switcher's order, search and row state text (board #250,
/// variant F), kept out of the views so it is testable.
package enum WorkbenchSwitcherPresentation {
    /// How a segment is drawn: the blue badge, orange, grey.
    package enum Tone: Equatable, Sendable {
        case comments
        case blocked
        case sessions
        case age
    }

    package struct Segment: Equatable, Sendable {
        package let text: String
        package let tone: Tone

        package init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    /// Most recent session activity first; workbenches without sessions
    /// follow, by name.
    package static func ordered(_ rows: [WorkbenchSwitcherSummary]) -> [WorkbenchSwitcherSummary] {
        rows.sorted { lhs, rhs in
            switch (lhs.lastSessionActivity.isEmpty, rhs.lastSessionActivity.isEmpty) {
            case (false, true): return true
            case (true, false): return false
            case (false, false) where lhs.lastSessionActivity != rhs.lastSessionActivity:
                return lhs.lastSessionActivity > rhs.lastSessionActivity
            default:
                let order = lhs.project.name.localizedCaseInsensitiveCompare(rhs.project.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        }
    }

    /// Case- and diacritic-insensitive substring match on the name or the
    /// folder; the order is kept.
    package static func matching(_ rows: [WorkbenchSwitcherSummary], query: String) -> [WorkbenchSwitcherSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            [row.project.name, row.project.folderPath].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// The row's state, left to right, each only when non-zero: new
    /// comments (`newComments` — the list row's badge number), blocked
    /// targets; then, with a session running, the sessions with the live
    /// ones, else the age of the last session activity (or nothing).
    package static func stateSegments(
        summary: WorkbenchSwitcherSummary,
        newComments: Int,
        liveCount: Int,
        now: Date
    ) -> [Segment] {
        var out: [Segment] = []
        if newComments > 0 {
            out.append(Segment(text: "\(newComments) new \(newComments == 1 ? "comment" : "comments")", tone: .comments))
        }
        if summary.blockedTargets > 0 {
            out.append(Segment(text: "\(summary.blockedTargets) blocked", tone: .blocked))
        }
        if liveCount > 0 {
            var sessions: [String] = []
            if summary.sessionCount > 0 {
                sessions.append("\(summary.sessionCount) \(summary.sessionCount == 1 ? "session" : "sessions")")
            }
            sessions.append("\(liveCount) running")
            out.append(Segment(text: sessions.joined(separator: " · "), tone: .sessions))
        } else if let age = TimeFormatting.shortAge(from: summary.lastSessionActivity, now: now) {
            out.append(Segment(text: age, tone: .age))
        }
        return out
    }
}
