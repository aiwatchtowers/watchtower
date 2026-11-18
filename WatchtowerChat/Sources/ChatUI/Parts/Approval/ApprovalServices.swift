import ChatWire
import SwiftUI

/// The owner's answer to an approval card, as the card hands it to the screen.
public enum ChatApprovalAnswer: Equatable, Sendable {
    /// Approve; `patch` carries the owner's card edits (`actions approve --patch`), nil for a plain approve.
    case approve(patch: String?)
    case reject
}

/// The phone's relay verb for an answer (`chat_action_answer` carries no patch).
public enum ChatApprovalDecision: Sendable, Equatable {
    case approve
    case reject
}

/// How an approval card's decision row stands, as the screen knows it: whether Approve and Reject show at all (the
/// device may answer), whether they are live (no answer on its way, the chat reachable), the line under them (where to
/// approve instead, the answer on its way, a refusal), and the Mac's gesture state (a CLI call in flight, why the last
/// one failed). Nil from `ChatApprovalServices.state` keeps the default: buttons live on a pending action.
public struct ChatApprovalState: Equatable, Sendable {
    public let showsButtons: Bool
    public let canAnswer: Bool
    public let line: String?
    /// A decision on this card is running (the Mac's CLI call): a spinner, and the row is off.
    public let inFlight: Bool
    /// Why the card's last Approve, Reject or Retry failed; the card hides it once the row says the same or settles.
    public let gestureError: String?
    /// The failed gesture was an approve: the prominent button becomes Retry, re-running the same approve.
    public let approveFailed: Bool
    /// The failure outlives the row's own state (an applied `create_track` whose `tracks start` failed).
    public let gestureErrorOutlivesRow: Bool
    /// Approve is not offered on this device: the note stands in its place ("Approve on the Mac", "Open Draft — on
    /// your Mac"); Reject keeps `canAnswer` (mobile Inbox spec §12.4). Nil on the Mac and in the phone chat.
    public let approveNote: String?
    /// Retry or Dismiss is not offered on this device (no grant, an older hub): the note stands in its place ("Retry
    /// on the Mac"). Nil keeps the offer.
    public let settledNote: String?
    /// Not delivered (the phone's outbox gave up): the line in red and the press's named Retry ("Retry Approve") as
    /// the row's one button, which re-sends the same action (`ChatApprovalServices.resend`).
    public let undelivered: Undelivered?

    /// A Not delivered press: its line and its named Retry.
    public struct Undelivered: Equatable, Sendable {
        public let line: String
        public let retryTitle: String

        public init(line: String, retryTitle: String) {
            self.line = line
            self.retryTitle = retryTitle
        }
    }

    public init(
        showsButtons: Bool,
        canAnswer: Bool,
        line: String?,
        inFlight: Bool = false,
        gestureError: String? = nil,
        approveFailed: Bool = false,
        gestureErrorOutlivesRow: Bool = false,
        approveNote: String? = nil,
        settledNote: String? = nil,
        undelivered: Undelivered? = nil
    ) {
        self.showsButtons = showsButtons
        self.canAnswer = canAnswer
        self.line = line
        self.inFlight = inFlight
        self.gestureError = gestureError
        self.approveFailed = approveFailed
        self.gestureErrorOutlivesRow = gestureErrorOutlivesRow
        self.approveNote = approveNote
        self.settledNote = settledNote
        self.undelivered = undelivered
    }
}

/// What an approval card may do, injected by the screen (ask #1409: one card, both devices). The card calls only these;
/// a capability that is nil hides its control. The Mac answers through `watchtower actions …` (`AgentActionFeed`, with
/// the owner-confirm), the phone through the hub's `chat_action_answer`; neither goes through `chat.sock` (D12).
public struct ChatApprovalServices {
    /// The Mac's loaded row for a part's action; nil (or a nil result) draws the card from the payload.
    public var resolve: ((ChatApprovalPayload) -> ChatAgentAction?)?
    /// Approve or reject, with the exact action the card showed (its args and digest, AGENT-07).
    public var decide: (ChatAgentAction, ChatApprovalAnswer) -> Void
    /// The decision row's state: an answer in flight, a gesture error, the phone's grant and line.
    public var state: ((ChatAgentAction) -> ChatApprovalState?)?
    /// The card may edit before approving (the Slack editor and workspace pick, a connector's Edit Input). Off on the
    /// phone: the relay answer carries no patch.
    public var approveEdited = false
    public var retry: ((ChatAgentAction) -> Void)?
    /// Dismiss a session call whose outcome is unknown (`ConnectorCallProposal.awaitsDismissal`).
    public var dismiss: ((ChatAgentAction) -> Void)?
    /// Sends a Not delivered press again (`ChatApprovalState.undelivered`, the phone Inbox's outbox).
    public var resend: ((ChatAgentAction) -> Void)?
    /// Approve every bulk-approvable card of a turn (**Approve all** under a reply).
    public var approveAll: ((_ turnID: String) -> Void)?
    /// Re-consents a Slack account whose token lacks the send grant; returns why it failed, nil on success.
    public var reconnectSlack: ((Int64) async -> String?)?
    /// Follows an applied action to what it produced, in the app (`AgentActionDestination`); nil hides **Open →**.
    public var openDestination: ((AgentActionDestination) -> Void)?
    /// A session-applied call: whether the live chat session that proposed it still waits on it. Nil: it does not.
    public var sessionHoldsCall: ((ChatAgentAction) -> Bool)?
    /// The card's own title for a tool the app draws itself (the Mac's `save_automation`); nil keeps the catalog's.
    public var title: ((ChatAgentAction) -> String?)?
    /// The body of a tool the app draws itself (the Mac's `save_automation`); nil keeps the shared body.
    public var details: ((ChatAgentAction) -> AnyView?)?
    /// What the app draws in place of the decision row (the Mac's Inbox target button: stuck, creating).
    public var decisionOverride: ((ChatAgentAction) -> AnyView?)?
    /// A card the app marks besides the one the running turn waits on (the Mac's actions under review).
    public var highlighted: ((ChatAgentAction) -> Bool)?

    public init(
        resolve: ((ChatApprovalPayload) -> ChatAgentAction?)? = nil,
        decide: @escaping (ChatAgentAction, ChatApprovalAnswer) -> Void = { _, _ in },
        state: ((ChatAgentAction) -> ChatApprovalState?)? = nil,
        approveEdited: Bool = false,
        retry: ((ChatAgentAction) -> Void)? = nil,
        dismiss: ((ChatAgentAction) -> Void)? = nil,
        approveAll: ((_ turnID: String) -> Void)? = nil,
        reconnectSlack: ((Int64) async -> String?)? = nil,
        openDestination: ((AgentActionDestination) -> Void)? = nil,
        sessionHoldsCall: ((ChatAgentAction) -> Bool)? = nil,
        title: ((ChatAgentAction) -> String?)? = nil,
        details: ((ChatAgentAction) -> AnyView?)? = nil,
        decisionOverride: ((ChatAgentAction) -> AnyView?)? = nil,
        highlighted: ((ChatAgentAction) -> Bool)? = nil,
        resend: ((ChatAgentAction) -> Void)? = nil
    ) {
        self.resolve = resolve
        self.decide = decide
        self.state = state
        self.approveEdited = approveEdited
        self.retry = retry
        self.dismiss = dismiss
        self.approveAll = approveAll
        self.reconnectSlack = reconnectSlack
        self.openDestination = openDestination
        self.sessionHoldsCall = sessionHoldsCall
        self.title = title
        self.details = details
        self.decisionOverride = decisionOverride
        self.highlighted = highlighted
        self.resend = resend
    }
}
