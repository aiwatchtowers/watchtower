import Foundation
import WatchtowerKit
import WatchtowerSync

/// The card under the workchat's header that says what to do next (#1784):
/// built from the session's published record only, so it shows before the
/// chat arrives and while the Mac is asleep. Finished: the agent's summary,
/// the PR line and Report. Failed: Continue (a line, where the phone may
/// type) or a new session on the target. Not running: a new session. Needs
/// approval with no request on the phone: where to answer it. No card while
/// the agent works or waits on an ask, on an idle session (the composer is
/// its continue), or when the permission card shows.
///
/// The phone has no restart or resume: the Mac takes a line, Stop, Finish,
/// Interrupt and a new session (`session_start`), nothing else.
struct WorkchatStateCard: Equatable {
    enum Action: Hashable {
        case report
        /// Sends `continueLine` as a line, as the composer would.
        case continueSession
        /// Opens Start session with the target fixed; nil = no target.
        case newSession(targetID: Int64?)

        var title: String {
            switch self {
            case .report: "Report"
            case .continueSession: "Continue"
            // Short enough to share a row with Continue; the text names the target.
            case .newSession: "New session"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .report: "Opens the session's report and timeline"
            case .continueSession: "Sends “\(WorkchatStateCard.continueLine)” to the session"
            case let .newSession(targetID): "Starts a new session \(WorkchatStateCard.onTarget(targetID))on your tower"
            }
        }
    }

    /// "on #416 " or "".
    static func onTarget(_ targetID: Int64?) -> String {
        targetID.map { "on #\($0) " } ?? ""
    }

    static let continueLine = "Continue"

    let title: String
    /// The agent's finish summary; the view clips it, the report has it whole.
    let summary: String?
    let details: [String]
    /// At most two; the first is the primary one when it is not Report.
    let actions: [Action]

    /// nil when the session needs no card.
    init?(session: TerminalSessionState, input: SessionInputModel, permission: PermissionCardModel?, macOnline: Bool) {
        let newSession = Action.newSession(targetID: session.targetID)
        let aNewSession = "a new session \(Self.onTarget(session.targetID))"
        switch session.stateKind {
        case .finished:
            title = "Finished"
            summary = session.finishSummary.isEmpty ? nil : session.finishSummary
            details = [session.reportPRLine].compactMap { $0?.isEmpty == false ? $0 : nil }
            actions = [.report]
        case .failed where session.live:
            title = "Stopped on an error"
            summary = nil
            // A line already on its way would be sent twice.
            if input.canSend {
                details = ["It still runs on your tower. Continue sends it “\(Self.continueLine)”, or start \(aNewSession)here."]
                // `continues` is the rule Now and the Sessions tab wait on (`SessionInputModel.waitsToContinue`).
                actions = input.continues ? [.continueSession, newSession] : [newSession]
            } else {
                details = ["It still runs on your tower: continue it there, or start \(aNewSession)here."]
                actions = [newSession]
            }
        case .failed, .stopped, .notStarted:
            // `stopped` is "Idle" on a live session: the composer continues it.
            guard !session.live else { return nil }
            title = "Not running"
            summary = nil
            details = ["Its run ended on your tower. Start \(aNewSession)to pick the work up."]
            actions = [newSession]
        case .needsApproval where permission == nil:
            title = "Needs approval"
            summary = nil
            details = [Self.approvalText(session, macOnline: macOnline)]
            actions = []
        default:
            return nil
        }
    }

    /// Where a prompt the phone has no card for gets its answer.
    static func approvalText(_ session: TerminalSessionState, macOnline: Bool) -> String {
        if !session.takesFromPhone.permissionAnswer {
            "Answer this prompt on the tower."
        } else if macOnline {
            "The request is on its way from your tower."
        } else {
            "Your tower sends the request when it wakes."
        }
    }
}
