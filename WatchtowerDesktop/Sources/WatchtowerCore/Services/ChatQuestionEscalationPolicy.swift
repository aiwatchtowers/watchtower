import Foundation

/// When the Desktop raises a recorded Chat question into an ask (spec
/// 2026-10-10-owner-asks-v2 Part 5.2): the agent asked in the terminal while
/// the owner was in the session, and the owner stays silent for 10 minutes,
/// leaves the session for longer than the leave grace, or was already away
/// when it was recorded. Pure; `ChatQuestionEscalator` runs
/// `watchtower workbench escalate-question` on an `.escalate`.
///
/// Never escalates a row Go's compare-and-take would refuse as gone
/// (`db.TakeChatQuestion`): a live workbench session of this run, its trusted
/// hook state `waiting`, `agent_state_at` at most `stateToleranceMillis` after the
/// question.
package enum ChatQuestionEscalationPolicy {
    /// How long a present owner may stay silent.
    package static let timeout: TimeInterval = 600
    /// How long the owner may be away from the session before it counts as
    /// leaving — an alt-tab to look something up does not.
    package static let leaveGrace: TimeInterval = 90
    /// The hard cap: raised at this age, a draft in the prompt or not.
    package static let draftCap: TimeInterval = 1800
    /// A stamp further ahead of the Desktop's clock is not trusted.
    package static let futureTolerance: TimeInterval = 5
    /// Go's `chatQuestionStateTolerance`, in milliseconds (the stamps'
    /// resolution): the Stop's own `waiting` may be stamped just after the
    /// guard recorded the question.
    package static let stateToleranceMillis: Int64 = 30_000

    package enum Reason: String, CaseIterable, Equatable, Sendable {
        case timeout, left, away
    }

    package enum Decision: Equatable, Sendable {
        case none
        /// `chat_question_at` does not parse or is more than
        /// `futureTolerance` ahead of the clock: nothing to do, but the
        /// runner logs it once.
        case unreadableStamp
        case escalate(Reason)
    }

    /// Where the owner is relative to the session, from the Desktop's live
    /// presence (not the row).
    package enum Presence: Equatable, Sendable {
        case present
        /// Not in the session since `since` (the 2 s-debounced loss).
        case away(since: Date)
    }

    /// `row` is the session's `fetchAgentStates` row; `live` and `startedAt`
    /// are the session's process and its start, carrying
    /// `SessionAgentStatus.effective`'s run rules (a state written before
    /// `startedAt`, or with no known start, is no state); `hasOwnerDraft` is
    /// text the owner typed in the session's prompt and has not submitted.
    package static func decide(
        row: SessionAgentStateRow,
        live: Bool,
        startedAt: Date?,
        presence: Presence,
        hasOwnerDraft: Bool,
        now: Date
    ) -> Decision {
        guard live, row.projectID != nil, row.chatQuestion != nil, let rawAt = row.chatQuestionAt,
              SessionAgentStatus.trustedHook(row, startedAt: startedAt) == .waiting else { return .none }
        guard let asked = SessionAgentStatus.parseStamp(rawAt), asked.timeIntervalSince(now) <= futureTolerance else {
            return .unreadableStamp
        }
        guard let stateAt = row.agentStateAt.flatMap(SessionAgentStatus.parseStamp),
              Int64((stateAt.timeIntervalSince(asked) * 1000).rounded()) <= stateToleranceMillis else { return .none }
        let age = now.timeIntervalSince(asked)
        if age >= draftCap { return .escalate(.timeout) }
        if hasOwnerDraft { return .none }
        switch presence {
        case let .away(since):
            if since <= asked { return .escalate(.away) }
            return now.timeIntervalSince(since) >= leaveGrace ? .escalate(.left) : .none
        case .present:
            return age >= timeout ? .escalate(.timeout) : .none
        }
    }
}
