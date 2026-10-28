import SwiftUI
import WatchtowerCore

/// "Edit before accepting": the destination's whole proposed text in one
/// editor (a one-field form); Accept sends the edited text.
struct CoachEditSheet: View {
    let proposal: CoachProposal
    let coach: CoachCenter
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(proposal: CoachProposal, coach: CoachCenter) {
        self.proposal = proposal
        self.coach = coach
        _text = State(initialValue: proposal.after)
    }

    private var sizeLine: String {
        let size = text.unicodeScalars.count
        let base = proposal.destinationLabel
        return proposal.budget > 0 ? "\(base) · \(size) of \(proposal.budget)" : base
    }

    private var overBudget: Bool { proposal.budget > 0 && text.unicodeScalars.count > proposal.budget }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Edit before accepting").font(.headline)
            Text(sizeLine).font(.caption).foregroundStyle(overBudget ? Tone.warning : .secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(Spacing.compact)
                .frame(minHeight: 160)
                .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
            Text("The whole text of the destination is saved as written here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
                Button("Accept") {
                    let edited = text
                    Task {
                        await coach.accept(proposal.id, editedText: edited)
                        dismiss()
                    }
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || overBudget || coach.pending.contains(proposal.id))
            }
        }
        .controlSize(.small)
        .padding(Spacing.large)
        .frame(width: 520)
    }
}
