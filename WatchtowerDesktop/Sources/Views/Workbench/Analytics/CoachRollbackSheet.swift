import SwiftUI
import WatchtowerCore

/// The destination changed since the accept: its diff, then Roll Back Anyway
/// or Cancel — or, for a pull-request edit, only Close (`CoachRollbackTexts`).
struct CoachRollbackSheet: View {
    let proposal: CoachProposal
    let diff: String
    let coach: CoachCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let texts = CoachRollbackTexts(proposal)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(texts.title).font(.headline)
            Text(texts.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(diff.isEmpty ? CoachRollbackTexts.noDiff : diff)
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
                if texts.offersForce {
                    Button(texts.dismiss) { dismiss() }.buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
                    Button(CoachRollbackTexts.rollBackAnyway) {
                        Task {
                            _ = await coach.rollback(proposal.id, force: true)
                            if coach.cardErrors[proposal.id] == nil { dismiss() }
                        }
                    }
                    .buttonStyle(.kitDestructive)
                    .disabled(coach.pending.contains(proposal.id))
                } else {
                    Button(texts.dismiss) { dismiss() }
                        .buttonStyle(.kitSecondary)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .controlSize(.small)
        .padding(Spacing.large)
        .frame(width: 520)
    }
}
