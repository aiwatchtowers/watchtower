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
    /// A phone start launched Codex and the login shell found no `codex`.
    case codexNotFound = "codex_not_found"
    case expired
    case cancelled
    /// The hub restarted between `begun` and `done` (spec §5.2 rule 1).
    case outcomeUnknown = "outcome_unknown"
    case unsupportedInPOC = "unsupported_in_poc"
    /// The record names another hub (multi-hub spec §3.5).
    case wrongHub = "wrong_hub"
    case writeFailed = "write_failed"
    /// A permission answer for a request that is no longer pending (answered on the Mac, or closed).
    case notPending = "not_pending"
    /// An interrupt for a session that is not Working.
    case notWorking = "not_working"
    /// An allow the phone may not give: the request was shortened, or edits a settings file (`PermissionAllowBlock`).
    /// Deny still works; the request stays pending for the Mac.
    case answerOnMac = "answer_on_mac"
    /// The Mac or the session's agent cannot do this for the phone (a Codex
    /// session's permission prompt or Interrupt, a recording on a host without
    /// the transcriber); the echo's message says what to do. An older phone
    /// decodes it to nil and shows that message (plan 2026-11-05 Task G7).
    case notSupported = "not_supported"
    /// A chat turn refused because another turn of the conversation holds the lease (iPhone chat spec §4.5).
    case conversationBusy = "conversation_busy"
    /// A chat turn names an attachment the hub never received or no longer holds.
    case attachmentMissing = "attachment_missing"
    /// A chat action answer whose `args_sha256` no longer matches the action's args: "The action changed".
    case changed
}

/// The reasons a chat action can fail with that the chat screens treat specially (iPhone chat spec §4.5). Every other
/// reason shows the echo's message as it is.
public enum ChatActionReason: Sendable {
    case conversationBusy
    case attachmentMissing
    case actionChanged
    /// Chat is off on this host (`chat` capability not on); the echo's message says what to do.
    case notSupported
    case notFound

    public init?(_ reason: ActionReason?) {
        switch reason {
        case .conversationBusy: self = .conversationBusy
        case .attachmentMissing: self = .attachmentMissing
        case .changed: self = .actionChanged
        case .notSupported: self = .notSupported
        case .notFound: self = .notFound
        default: return nil
        }
    }
}
