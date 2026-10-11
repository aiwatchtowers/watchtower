import Foundation

/// The closed `reason` code the Mac writes on an action's failure, hold or
/// expiry (mobile POC spec §5.2). rawValues are wire format — never rename.
public enum ActionReason: String, Codable, CaseIterable, Sendable {
    case notFound = "not_found"
    case notOnBoard = "not_on_board"
    case askNotOpen = "ask_not_open"
    case invalidAnswer = "invalid_answer"
    case invalidParams = "invalid_params"
    case conflict
    case deviceNotAllowed = "device_not_allowed"
    /// The record did not come from a linked device (spec §5.2 rule 4).
    case deviceNotLinked = "device_not_linked"
    case sessionNotRunning = "session_not_running"
    case agentBusy = "agent_busy"
    case needsApproval = "needs_approval"
    case promptHasText = "prompt_has_text"
    case stateUnknown = "state_unknown"
    case cannotType = "cannot_type"
    case claudeNotFound = "claude_not_found"
    case expired
    case cancelled
    /// The hub restarted between `begun` and `done` (spec §5.2 rule 1).
    case outcomeUnknown = "outcome_unknown"
    case unsupportedInPOC = "unsupported_in_poc"
    case writeFailed = "write_failed"
}
