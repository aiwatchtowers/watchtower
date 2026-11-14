import SwiftUI
import WatchtowerCore

/// The Context block's **Do these** list (context actions, spec 2026-11-12
/// part 4): one row per change with its saving, title, tag, evidence, where
/// it is and the buttons its state allows; below, the faded done rows. The
/// rows come from `ContextActionsPresentation`; a press goes to `perform`,
/// after a confirmation for Decline and Revert….
struct ContextActionsView: View {
    let doThese: [ContextActionRow]
    let done: [ContextActionRow]
    /// Rows with a verb in flight (`CoachCenter.pending`): buttons disabled.
    var busy: Set<Int64> = []
    /// A failed verb's line (`CoachCenter.cardErrors`).
    var errors: [Int64: String] = [:]
    let perform: (ContextActionRow.Action, ContextActionRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Do these").font(.callout.weight(.semibold))
            ForEach(doThese) { row in rowView(row, faded: false) }
            ForEach(done) { row in rowView(row, faded: true) }
        }
        .controlSize(.small)
    }

    /// A done row fades its text, not its buttons: Undo stays legible.
    private func rowView(_ row: ContextActionRow, faded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                Text(Self.savingLabel(row))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Tone.success)
                    .frame(width: ListLayout.numberColumn, alignment: .trailing)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(spacing: Spacing.compact) {
                        Text(row.proposal.title).font(.callout.weight(.medium))
                        Chip(text: row.tag.label, color: .secondary)
                    }
                    if !row.evidence.isEmpty {
                        Text(row.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                    ContextActionLines(row: row, error: errors[row.id])
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(faded ? 0.6 : 1)
            Spacer(minLength: Spacing.regular)
            ContextActionButtons(row: row, busy: busy.contains(row.id), perform: perform)
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.regular)
        .kitRow(isSelected: false)
    }

    // MARK: - Lines

    static let startingLine = "Starting a session…"

    /// "−30.2k"; a done row "✓ −6.1k" (or "✓"); "" without a saving.
    static func savingLabel(_ row: ContextActionRow) -> String {
        let saving = row.savingText ?? ""
        guard isDone(row.state) else { return saving }
        return saving.isEmpty ? "✓" : "✓ " + saving
    }

    /// Where a session row is when its buttons alone do not say it.
    static func progressLine(_ row: ContextActionRow) -> String? {
        switch row.state {
        case .working: return "Session working"
        case let .reverting(session): return "Revert session #\(session)"
        case let .prReady(pr, _): return "PR #\(pr) ready"
        case .measuring:
            return row.tag == .memory ? "Index written · measuring" : "Merged · measuring"
        default: return nil
        }
    }

    private static func isDone(_ state: ContextActionRow.State) -> Bool {
        switch state {
        case .done, .measuring: return true
        default: return false
        }
    }

    static func isFailed(_ state: ContextActionRow.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    static func isWarning(_ state: ContextActionRow.State) -> Bool {
        switch state {
        case .failed, .linkFailed, .revertedOutside, .sessionGone: return true
        default: return false
        }
    }
}

/// Where a row is: starting, its progress, its state line, the measured
/// numbers and a failed verb's line.
struct ContextActionLines: View {
    let row: ContextActionRow
    var error: String?

    var body: some View {
        if row.state == .starting {
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text(ContextActionsView.startingLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let line = ContextActionsView.progressLine(row) {
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
        if let line = row.stateLine {
            Text(line).font(.caption)
                .foregroundStyle(ContextActionsView.isWarning(row.state) ? Tone.warning : .secondary)
        }
        if let numbers = row.beforeAfter {
            Text(numbers).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        // A failed start shows its message as the state line already.
        if let error, !ContextActionsView.isFailed(row.state) {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
        }
    }
}

/// A row's buttons, in the order its state allows; Decline and Revert…
/// are confirmed first.
struct ContextActionButtons: View {
    let row: ContextActionRow
    var busy = false
    let perform: (ContextActionRow.Action, ContextActionRow) -> Void

    @State private var confirmDecline = false
    @State private var confirmRevert = false

    var body: some View {
        HStack(spacing: Spacing.compact) {
            ForEach(row.actions, id: \.self) { action in
                switch action {
                case .decline:
                    Button(action.title) { confirmDecline = true }.buttonStyle(.kitQuiet)
                case .revert:
                    Button(action.title) { confirmRevert = true }.buttonStyle(.kitSecondary)
                default:
                    Button(action.title) { perform(action, row) }.buttonStyle(.kitSecondary)
                }
            }
        }
        .fixedSize()
        .disabled(busy)
        .confirmationDialog("Decline this change?", isPresented: $confirmDecline) {
            Button("Decline", role: .destructive) { perform(.decline, row) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Decline for good? It will not be proposed again.")
        }
        .confirmationDialog("Revert this change?", isPresented: $confirmRevert) {
            Button("Start Revert Session") { perform(.revert, row) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A session opens a PR that reverts the merged change. Nothing is merged without you.")
        }
    }
}
