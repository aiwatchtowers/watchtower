import Foundation

/// When a workbench session's agent turns to the owner (spec
/// 2026-10-03-session-agent-state, decision 12), kept pure so the center
/// only feeds it statuses and posts what it returns. Each transition into
/// waiting or approval — one `(session, agent_state_at)` — is announced at
/// most once; a transition seen while notices may not be posted (the app is
/// active, notifications are off, quiet hours) is consumed, never replayed.
package struct SessionAgentNoticePolicy: Sendable {
    package struct Notice: Equatable, Sendable {
        package let sessionID: Int64
        package let workbenchID: Int64
        package let title: String
        package let body: String

        package init(sessionID: Int64, workbenchID: Int64, title: String, body: String) {
            self.sessionID = sessionID
            self.workbenchID = workbenchID
            self.title = title
            self.body = body
        }

        /// One per session, so a newer state replaces its older banner.
        package var identifier: String { SessionAgentNoticePolicy.identifier(sessionID: sessionID) }
    }

    package enum Action: Equatable, Sendable {
        case post(Notice)
        /// The session is working again or no longer live: its delivered
        /// banner goes.
        case withdraw(identifier: String)
    }

    package static func identifier(sessionID: Int64) -> String { "workbench-session-\(sessionID)" }

    /// The waiting/approval transition each session last saw, by its stamp.
    private var seen: [Int64: String] = [:]

    package init() {}

    /// `statuses` is the whole live map of one poll; `canPost` is false while
    /// the app is active, the workbench notifications toggle is off or quiet
    /// hours are on.
    package mutating func update(_ statuses: [Int64: SessionAgentStatus], canPost: Bool) -> [Action] {
        var actions: [Action] = []
        for id in seen.keys.sorted() where !Self.asksForOwner(statuses[id]) {
            seen[id] = nil
            actions.append(.withdraw(identifier: Self.identifier(sessionID: id)))
        }
        for status in statuses.values.sorted(by: { $0.sessionID < $1.sessionID }) {
            guard Self.asksForOwner(status), let at = status.at, seen[status.sessionID] != at else { continue }
            seen[status.sessionID] = at
            if canPost, let notice = Self.notice(for: status) { actions.append(.post(notice)) }
        }
        return actions
    }

    private static func asksForOwner(_ status: SessionAgentStatus?) -> Bool {
        status?.state == .waitingForOwner || status?.state == .needsApproval
    }

    /// nil for a standalone terminal or a workbench that no longer exists.
    private static func notice(for status: SessionAgentStatus) -> Notice? {
        guard let workbenchID = status.workbenchID, let name = status.workbenchName else { return nil }
        let title = status.state == .needsApproval
            ? "\(status.title) needs approval"
            : "\(status.title) is waiting for you"
        return Notice(sessionID: status.sessionID, workbenchID: workbenchID, title: title, body: name)
    }
}
