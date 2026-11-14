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

    @State private var confirmDecline: ContextActionRow?
    @State private var confirmRevert: ContextActionRow?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Do these").font(.callout.weight(.semibold))
            ForEach(doThese) { row in rowView(row) }
            ForEach(done) { row in
                rowView(row).opacity(0.6)
            }
        }
        .controlSize(.small)
        .confirmationDialog("Decline this change?", isPresented: presented($confirmDecline), presenting: confirmDecline) { row in
            Button("Decline", role: .destructive) { perform(.decline, row) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Decline for good? It will not be proposed again.")
        }
        .confirmationDialog("Revert this change?", isPresented: presented($confirmRevert), presenting: confirmRevert) { row in
            Button("Start Revert Session") { perform(.revert, row) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("A session opens a PR that reverts the merged change. Nothing is merged without you.")
        }
    }

    private func rowView(_ row: ContextActionRow) -> some View {
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
                lines(row)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            buttons(row)
        }
        .padding(.vertical, Spacing.compact)
        .padding(.horizontal, Spacing.regular)
        .kitRow(isSelected: false)
    }

    @ViewBuilder private func lines(_ row: ContextActionRow) -> some View {
        if row.state == .starting {
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text(Self.startingLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let line = Self.progressLine(row) {
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
        if let line = row.stateLine {
            Text(line).font(.caption).foregroundStyle(Self.isWarning(row.state) ? Tone.warning : .secondary)
        }
        if let numbers = row.beforeAfter {
            Text(numbers).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        // A failed start shows its message as the state line already.
        if let error = errors[row.id], !Self.isFailed(row.state) {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
        }
    }

    private func buttons(_ row: ContextActionRow) -> some View {
        HStack(spacing: Spacing.compact) {
            ForEach(row.actions, id: \.self) { action in
                switch action {
                case .decline:
                    Button(action.title) { confirmDecline = row }.buttonStyle(.kitQuiet)
                case .revert:
                    Button(action.title) { confirmRevert = row }.buttonStyle(.kitSecondary)
                case .undo:
                    Button(action.title) { perform(action, row) }.buttonStyle(.kitQuiet)
                default:
                    Button(action.title) { perform(action, row) }.buttonStyle(.kitSecondary)
                }
            }
        }
        .fixedSize()
        .disabled(busy.contains(row.id))
    }

    private func presented(_ binding: Binding<ContextActionRow?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
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

    private static func isFailed(_ state: ContextActionRow.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func isWarning(_ state: ContextActionRow.State) -> Bool {
        switch state {
        case .failed, .linkFailed, .revertedOutside, .sessionGone: return true
        default: return false
        }
    }
}
