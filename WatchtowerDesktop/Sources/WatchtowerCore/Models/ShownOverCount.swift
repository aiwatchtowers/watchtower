import Foundation

/// A background agent count the state center shows as over: the session's
/// run and the count's `agent_background_at` it was judged for.
package struct ShownOverCount: Equatable, Sendable {
    package let run: Date?
    package let reportedAt: String?

    package init(run: Date?, reportedAt: String?) {
        self.run = run
        self.reportedAt = reportedAt
    }

    /// `over`'s sessions with the run and report stamp of `rows`.
    package static func of(_ over: Set<Int64>, rows: [SessionAgentStateRow], startedAt: [Int64: Date]) -> [Int64: Self] {
        var counts: [Int64: Self] = [:]
        for row in rows where over.contains(row.id) {
            counts[row.id] = Self(run: startedAt[row.id], reportedAt: row.agentBackgroundAt)
        }
        return counts
    }
}
