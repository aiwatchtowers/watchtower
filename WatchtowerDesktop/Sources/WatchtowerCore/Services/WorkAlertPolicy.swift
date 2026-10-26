import Foundation

/// Which stops of work alert the phone (spec 2026-10-25-mobile-workbench-remote §5.2): one candidate per stop,
/// never two for one stop. Pure: the hub's `WorkAlertSlice` reads the inputs, gates on the owner being away and
/// remembers what it pushed.
///
/// - every open ask → `ask` (a Ready to check session pushes as its check or review ask);
/// - every pending permission request → `permission`;
/// - a Finished or Stopped session → `sessionStopped`, a Failed one → `sessionFailed`, only when its state is dated,
///   has held `stopHold` and nothing else stands for the stop: no open ask of the session (the ask pushes) and no
///   pending request (the request pushes). Waiting on an ask, Ready to check and Needs approval never yield a session
///   candidate: their ask or request does.
///
/// Keys are one per occurrence and match the Kit's `WorkAlertKey` (a dual path, pinned by `WorkAlertSliceTests`):
/// `ask-<id>`, `perm-<id>`, `stop-<session>-<state_at in whole unix ms>`.
///
/// Text: `title` is the session's title when the session is known ('' otherwise; the slice puts the workbench name
/// before it), `body` is the ask's title, "Needs approval: <tool>", "Finished" (finished), "Waiting for you"
/// (stopped: the turn is over and the agent waits for input) or "Failed".
package enum WorkAlertPolicy {
    /// How long a Stopped/Finished/Failed state must hold before it pushes: the Mac has no session-state notice
    /// debounce to reuse (spec §5.2).
    package static let stopHold: TimeInterval = 20
    /// How recent a stop seen at the Mac must be to push when the owner leaves (spec §4, no push storm): a stop
    /// that began more than this before the departure stays on the Mac. Asks and requests have no such limit.
    package static let departureWindow: TimeInterval = 30 * 60

    package enum Event: String, Sendable {
        case ask, permission
        case sessionStopped = "session_stopped"
        case sessionFailed = "session_failed"
    }

    package struct AskInput: Equatable, Sendable {
        package let id: Int64
        package let workbenchID: Int64
        package let sessionID: Int64?
        package let title: String
        /// `owner_asks.kind` (`question`, `check`, `review`).
        package let kind: String
        package let createdAt: Date

        package init(id: Int64, workbenchID: Int64, sessionID: Int64?, title: String, kind: String, createdAt: Date) {
            self.id = id
            self.workbenchID = workbenchID
            self.sessionID = sessionID
            self.title = title
            self.kind = kind
            self.createdAt = createdAt
        }
    }

    package struct RequestInput: Equatable, Sendable {
        package let id: Int64
        package let sessionID: Int64
        package let workbenchID: Int64
        package let toolName: String
        package let createdAt: Date

        package init(id: Int64, sessionID: Int64, workbenchID: Int64, toolName: String, createdAt: Date) {
            self.id = id
            self.sessionID = sessionID
            self.workbenchID = workbenchID
            self.toolName = toolName
            self.createdAt = createdAt
        }
    }

    package struct SessionInput: Equatable, Sendable {
        package let id: Int64
        package let workbenchID: Int64
        package let title: String
        package let kind: SessionSwitcherPresentation.State.Kind
        /// When the current state was entered; nil when unknown (never pushes).
        package let stateAt: Date?
        package let openAsks: Int
        package let hasPendingRequest: Bool

        package init(
            id: Int64,
            workbenchID: Int64,
            title: String,
            kind: SessionSwitcherPresentation.State.Kind,
            stateAt: Date?,
            openAsks: Int,
            hasPendingRequest: Bool
        ) {
            self.id = id
            self.workbenchID = workbenchID
            self.title = title
            self.kind = kind
            self.stateAt = stateAt
            self.openAsks = openAsks
            self.hasPendingRequest = hasPendingRequest
        }
    }

    package struct Candidate: Equatable, Sendable {
        package let key: String
        package let event: Event
        package let workbenchID: Int64
        package let sessionID: Int64?
        package let askID: Int64?
        package let requestID: Int64?
        /// When the stop began: the ask's or request's `created_at`, the session state's `state_at`.
        package let startedAt: Date
        /// The session's title, '' when the session is unknown.
        package let title: String
        package let body: String
    }

    /// Asks first, then requests, then sessions, each in input order.
    package static func candidates(
        asks: [AskInput], requests: [RequestInput], sessions: [SessionInput], now: Date
    ) -> [Candidate] {
        let titles = Dictionary(sessions.map { ($0.id, $0.title) }) { first, _ in first }
        let sessionTitle: (Int64?) -> String = { id in id.flatMap { titles[$0] } ?? "" }
        let forAsks = asks.map { ask in
            Candidate(
                key: "ask-\(ask.id)", event: .ask, workbenchID: ask.workbenchID, sessionID: ask.sessionID, askID: ask.id,
                requestID: nil, startedAt: ask.createdAt, title: sessionTitle(ask.sessionID), body: ask.title
            )
        }
        let forRequests = requests.map { request in
            Candidate(
                key: "perm-\(request.id)", event: .permission, workbenchID: request.workbenchID, sessionID: request.sessionID,
                askID: nil, requestID: request.id, startedAt: request.createdAt, title: sessionTitle(request.sessionID),
                body: "Needs approval: \(request.toolName)"
            )
        }
        let forSessions = sessions.compactMap { session -> Candidate? in
            guard let stop = stop(session.kind), let stateAt = session.stateAt,
                  now.timeIntervalSince(stateAt) >= stopHold,
                  session.openAsks == 0, !session.hasPendingRequest else { return nil }
            return Candidate(
                key: stopKey(session: session.id, stateAt: stateAt), event: stop.event, workbenchID: session.workbenchID,
                sessionID: session.id, askID: nil, requestID: nil, startedAt: stateAt, title: session.title, body: stop.body
            )
        }
        return forAsks + forRequests + forSessions
    }

    /// Whether `candidate` is new enough to alert at all: asks from the hub's `enabled_at` (their earlier alerts
    /// were migrated as pushed), requests and stops also from the work alerts' own start, so an upgraded hub never
    /// alerts on what was already waiting.
    package static func counts(_ candidate: Candidate, enabledAt: Date, workAlertsStartedAt: Date) -> Bool {
        switch candidate.event {
        case .ask: candidate.startedAt >= enabledAt
        case .permission, .sessionStopped, .sessionFailed: candidate.startedAt >= max(enabledAt, workAlertsStartedAt)
        }
    }

    /// Whether `candidate`, not pushed yet, pushes while the owner is away since `awaySince`: an ask or a request
    /// always; a stop only when it began within `departureWindow` before the departure (one while away always does).
    package static func pushesWhileAway(_ candidate: Candidate, awaySince: Date) -> Bool {
        switch candidate.event {
        case .ask, .permission: true
        case .sessionStopped, .sessionFailed: candidate.startedAt >= awaySince.addingTimeInterval(-departureWindow)
        }
    }

    /// The stops an ask or a request stands for now: every dated session with an open ask or a pending request.
    /// When that ask or request resolves and the session still reads Stopped/Finished at the same `state_at` (an
    /// answer to a finished session's check, a held answer), its stop key is the same one: the slice remembers these
    /// keys so that stop never pushes a second time.
    package static func coveredStopKeys(sessions: [SessionInput]) -> [String] {
        sessions.compactMap { session in
            guard let stateAt = session.stateAt, session.openAsks > 0 || session.hasPendingRequest else { return nil }
            return stopKey(session: session.id, stateAt: stateAt)
        }
    }

    /// The Kit's `WorkAlertKey.stop`: whole unix milliseconds, rounded to the nearest.
    package static func stopKey(session: Int64, stateAt: Date) -> String {
        "stop-\(session)-\(Int64((stateAt.timeIntervalSince1970 * 1000).rounded()))"
    }

    private static func stop(_ kind: SessionSwitcherPresentation.State.Kind) -> (event: Event, body: String)? {
        switch kind {
        case .finished: (.sessionStopped, "Finished")
        case .stopped: (.sessionStopped, "Waiting for you")
        case .failed: (.sessionFailed, "Failed")
        case .notStarted, .running, .working, .needsApproval, .waitingOnAsk, .background, .readyToCheck: nil
        }
    }
}
