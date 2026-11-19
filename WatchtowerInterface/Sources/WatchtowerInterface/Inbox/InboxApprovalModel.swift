import Foundation

/// A Needs approval card's decision row (mobile Inbox spec §4.3, mockup §3).
/// Approve pins the SHA-256 of the arguments drawn, so a proposal changed
/// meanwhile is refused `args_changed` and redrawn. On the phone Approve,
/// Retry and Dismiss need the `permissions` grant ("Approve on the Mac"
/// without it), and Edit… and Open Draft stay on the Mac.
public struct InboxApprovalModel: Equatable, Sendable {
    /// What an Inbox target button's proposal draws in place of the decision
    /// row (the Mac's `AgentActionCardView.targetRow`): stuck, or failed on a
    /// row that is not itself failed, offers Try again; creating shows
    /// progress only; anything else keeps the decision row.
    public enum TargetRow: Equatable, Sendable {
        case stuck, inFlight, decision
    }

    public let cardID: String
    public let approval: Approval?
    public let canApprove: Bool
    /// Why Approve is not offered on the phone: "Approve on the Mac" without
    /// the grant, "Open Draft — on your Mac" for a save_automation.
    public let approveNote: String?
    public let canReject: Bool
    /// Retry of a failed row; never on a superseded one (the CLI refuses it).
    public let canRetry: Bool
    public let canEdit: Bool
    /// "Edit on your Mac" on the phone for a proposal the Mac's Edit… changes.
    public let editNote: String?
    public let targetRow: TargetRow

    public init(card: Card, platform: Platform, grants: Grants, now: Date = Date()) {
        cardID = card.id
        approval = card.approval
        let status = card.approval?.status ?? ""
        let pending = status == "pending"
        let failed = status == "failed"
        let mayDecide = platform == .mac || grants.permissions
        let draftOnMac = platform == .phone && card.approval?.tool == "save_automation"
        canApprove = pending && mayDecide && !draftOnMac
        if !pending || platform == .mac {
            approveNote = nil
        } else if draftOnMac {
            approveNote = TowerText.openDraftOnYourMac
        } else {
            approveNote = grants.permissions ? nil : TowerText.approveOnTheMac
        }
        canReject = pending
        canRetry = failed && mayDecide && card.approval?.superseded != true
        let editable = card.approval?.editOnMac == true && pending
        canEdit = editable && platform == .mac
        editNote = editable && platform == .phone ? TowerText.editOnYourMac : nil
        targetRow = Self.targetRow(card.approval, status: status, now: now)
    }

    /// Approve, pinned to the arguments drawn.
    public func approve(requestID: String) -> ActRequest {
        request(.approve, requestID: requestID)
    }

    /// An approval verb, pinned to the arguments drawn.
    public func request(_ verb: ApprovalVerb, requestID: String) -> ActRequest {
        ActRequest(
            requestID: requestID,
            target: cardID,
            verb: .approval,
            params: ActParams(approvalVerb: verb, argsSHA256: approval?.argsSHA256)
        )
    }

    /// A creating target past `target_until` reads as stuck by the client's
    /// clock (no write wakes a watch then).
    static func targetRow(_ approval: Approval?, status: String, now: Date) -> TargetRow {
        switch approval?.target ?? "" {
        case "stuck":
            return .stuck
        case "failed":
            return status == "failed" ? .decision : .stuck
        case "creating":
            let until = InboxTime.parse(approval?.targetUntil ?? "")
            return until.map { now >= $0 } == true ? .stuck : .inFlight
        default:
            return .decision
        }
    }
}
