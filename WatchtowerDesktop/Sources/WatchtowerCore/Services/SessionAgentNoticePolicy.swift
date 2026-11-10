import Foundation

/// When a live workbench session's agent turns to the owner (spec
/// 2026-10-03-session-agent-state, decision 12; the notices of spec
/// 2026-10-03-workbench-session-report §4b), kept pure so the center only
/// feeds it statuses and posts what it returns. Each transition into needs
/// approval, failed, stopped or finished — one `(session, kind,
/// agent_state_at)` — is announced at most once; a transition seen while
/// notices may not be posted (the app is active, notifications are off,
/// notifications are paused) is consumed, never replayed. Waiting on an ask, ready to
/// check (#534), or working with asks, gets no state notice:
/// `WorkbenchNotificationPolicy.askOpened` already announced the ask.
/// Background shells alone never hold the turn end back (ask #1217, board
/// #1712): a background session whose only work is shells is announced as
/// the kind it rests in without them, so the notice comes at the turn end
/// and the shells' end, at the same stamp, is no second one. Background
/// agents still hold it until they end.
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
        /// The session is working again (or in any other unannounced state)
        /// or no longer live: its delivered banner goes.
        case withdraw(identifier: String)
    }

    package static func identifier(sessionID: Int64) -> String { identifierPrefix + String(sessionID) }

    package static let identifierPrefix = "workbench-session-"

    /// The session banners among `identifiers` — the ones a launch or a
    /// quit removes (a banner outliving the process names a dead run).
    package static func noticeIdentifiers(in identifiers: [String]) -> [String] {
        identifiers.filter { id in
            id.hasPrefix(identifierPrefix) && Int64(id.dropFirst(identifierPrefix.count)) != nil
        }
    }

    /// The announced transition each session last saw, as `kind@stamp`.
    private var seen: [Int64: String] = [:]

    package init() {}

    /// `statuses` is the whole map of one read, live or not; `canPost` is
    /// false while the app is active, the workbench notifications toggle is
    /// off or notifications are paused.
    package mutating func update(_ statuses: [Int64: SessionAgentStatus], canPost: Bool) -> [Action] {
        var actions: [Action] = []
        for id in seen.keys.sorted() where Self.transition(statuses[id]) == nil {
            seen[id] = nil
            actions.append(.withdraw(identifier: Self.identifier(sessionID: id)))
        }
        for status in statuses.values.sorted(by: { $0.sessionID < $1.sessionID }) {
            guard let transition = Self.transition(status), seen[status.sessionID] != transition else { continue }
            seen[status.sessionID] = transition
            if canPost, let notice = Self.notice(for: status) { actions.append(.post(notice)) }
        }
        return actions
    }

    /// The announced transition a status stands for: a live session in
    /// needs approval, failed, stopped or finished, reached by a hook write
    /// of the current run; nil for anything else.
    private static func transition(_ status: SessionAgentStatus?) -> String? {
        guard let status, let kind = announcedKind(status), let at = status.at else { return nil }
        return "\(kind)@\(at)"
    }

    /// The kind a live status is announced as, nil when it is not: a
    /// shells-only background reads as its resting kind without the shells
    /// (the resting order of `SessionAgentStatus.effective`, turn ended; ask #1217) —
    /// only checks or reviews open (ready to check: the ask was announced),
    /// else finished, else any ask open (waiting on it), else stopped.
    private static func announcedKind(_ status: SessionAgentStatus) -> SessionSwitcherPresentation.State.Kind? {
        guard status.state.live else { return nil }
        switch status.state.kind {
        case .needsApproval, .failed, .stopped, .finished: return status.state.kind
        case .background where status.state.shellsOnly:
            if status.state.asksAreOnlyChecks { return nil }
            if status.finishedAt != nil { return .finished }
            return status.state.openAsks > 0 ? nil : .stopped
        case .notStarted, .running, .working, .waitingOnAsk, .readyToCheck, .background: return nil
        }
    }

    /// nil for a standalone terminal or a workbench that no longer exists.
    private static func notice(for status: SessionAgentStatus) -> Notice? {
        guard let workbenchID = status.workbenchID, let name = status.workbenchName,
              let kind = announcedKind(status) else { return nil }
        let (title, body): (String, String)
        switch kind {
        case .needsApproval:
            (title, body) = ("\(status.title) needs approval", name)
        case .failed:
            (title, body) = ("\(status.title) hit an error", SessionStatePresentation.caption(for: status.state))
        case .finished:
            (title, body) = ("\(status.title) finished", finishedBody(status) ?? name)
        default:
            // `stopped`, the only other announced kind.
            // Caption Idle since board #1712; the kind id stays `stopped`.
            (title, body) = ("\(status.title) is idle", name)
        }
        return Notice(sessionID: status.sessionID, workbenchID: workbenchID, title: title, body: body)
    }

    /// "N asks waiting for you" while asks are open, else the summary's
    /// first line; nil for neither.
    private static func finishedBody(_ status: SessionAgentStatus) -> String? {
        let asks = status.state.openAsks
        if asks > 0 { return asks == 1 ? "1 ask waiting for you" : "\(asks) asks waiting for you" }
        let line = status.finishSummary.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : line
    }
}
