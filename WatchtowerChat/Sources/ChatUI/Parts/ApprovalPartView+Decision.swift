import SwiftUI
import WatchtowerDesign

/// The approval card's decision row and status words, in one place.
extension ApprovalPartView {
    static let approveLabel = "Approve"
    static let rejectLabel = "Reject"

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "pending": "Awaiting your approval"
        case "approved": "Approved"
        case "executing": "Executing…"
        case "applied": "Done"
        case "rejected": "Rejected"
        case "failed": "Failed"
        default: status
        }
    }

    static func statusTone(_ status: String) -> Color {
        switch status {
        case "pending": Tone.warning
        case "applied": Tone.success
        case "failed": Tone.error
        default: .secondary
        }
    }

    @ViewBuilder var decisionRow: some View {
        if payload.isPending {
            HStack(spacing: Spacing.regular) {
                style.primaryButton(Self.approveLabel) { context.actions.decide(payload, .approve) }
                    .accessibilityIdentifier("chat.approval.approve")
                style.secondaryButton(Self.rejectLabel) { context.actions.decide(payload, .reject) }
                    .accessibilityIdentifier("chat.approval.reject")
            }
        } else if payload.status == "failed" || payload.status == "rejected", let reason = payload.reason, !reason.isEmpty {
            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }
    }
}
