import SwiftUI
import WatchtowerCore

/// Why Needs approval shows today's native cards instead of the recipe's,
/// and what its one press does (spec "Needs approval" → States).
struct NeedsApprovalNoteContent: Equatable {
    enum State: Equatable {
        /// The `approval-cards` feature is off: **Turn On** enables it.
        case off
        /// The built-in was stopped under AUTO-08 while the feature is on:
        /// its own **Turn On** resumes it (`resumeStoppedBuiltin`).
        case stopped
        /// The latest `needs-approval` run failed: **Run History**.
        case lastRunFailed
    }

    let state: State
    /// The reason the last Turn On returned; the note stays.
    var failure: String?
    /// A Turn On under way.
    var isApplying = false

    var text: String {
        switch state {
        case .off: "Showing approvals in the standard card — Needs approval is off."
        case .stopped:
            "Showing approvals in the standard card — Needs approval was stopped after a run that would not end."
        case .lastRunFailed: "Showing approvals in the standard card — the last run failed."
        }
    }

    var buttonTitle: String {
        state == .lastRunFailed ? "Run History" : "Turn On"
    }
}

/// The one-line note at the top of Needs approval while it falls back to
/// native cards (off, stopped, last run failed), with its press and the
/// reason a failed Turn On returned under it. No wiring (plan Task 1;
/// Task 12 hands in `onPress`).
struct NeedsApprovalNote: View {
    let content: NeedsApprovalNoteContent
    var onPress: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(content.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                if content.isApplying {
                    ProgressView().controlSize(.small)
                }
                Button(content.buttonTitle, action: onPress)
                    .buttonStyle(.kitSecondary)
                    .disabled(content.isApplying)
            }
            if let failure = content.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Fill.rest)
    }
}
