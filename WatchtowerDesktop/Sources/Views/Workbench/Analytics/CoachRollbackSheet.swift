import SwiftUI
import WatchtowerCore

/// The destination changed since the accept: its diff, then Roll Back Anyway
/// or Cancel.
struct CoachRollbackSheet: View {
    let proposal: CoachProposal
    let diff: String
    let coach: CoachCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("The text changed since you accepted").font(.headline)
            Text("\(proposal.destinationLabel) was edited after “\(proposal.title)”. Rolling back overwrites those edits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(diff.isEmpty ? "No diff available." : diff)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(Spacing.cozy)
            .frame(height: 140)
            .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
            if let error = coach.cardErrors[proposal.id] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
                Button("Roll Back Anyway") {
                    Task {
                        _ = await coach.rollback(proposal.id, force: true)
                        if coach.cardErrors[proposal.id] == nil { dismiss() }
                    }
                }
                .buttonStyle(.kitDestructive)
                .disabled(coach.pending.contains(proposal.id))
            }
        }
        .controlSize(.small)
        .padding(Spacing.large)
        .frame(width: 520)
    }
}
