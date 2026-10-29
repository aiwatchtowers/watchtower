import SwiftUI
import WatchtowerCore

/// An open Roll Back confirmation: the proposal and the destination's diff.
struct CoachRollbackPrompt: Identifiable {
    let proposal: CoachProposal
    let diff: String
    var id: Int64 { proposal.id }
}

/// The coach's three sections on the Analytics pane: How it's going,
/// Proposed edits (with the run line) and Accepted edits.
struct CoachSectionsView: View {
    let coach: CoachCenter
    let workbench: Int64
    let actions: CoachActions
    @State private var editing: CoachProposal?
    @State private var rollback: CoachRollbackPrompt?

    var body: some View {
        let status = coach.status[workbench]
        let split = CoachProposal.forPane(coach.proposals?.value ?? [], workbench: workbench)
        VStack(alignment: .leading, spacing: Spacing.page) {
            CoachMetricTilesView(snapshot: status)
            proposed(split.open, lastRun: status?.value?.lastRun)
            if coach.proposals?.value != nil {
                CoachAcceptedLogView(accepted: split.accepted, open: split.open, coach: coach) { proposal in
                    Task {
                        if let diff = await coach.rollback(proposal.id, force: false) {
                            rollback = CoachRollbackPrompt(proposal: proposal, diff: diff)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { CoachEditSheet(proposal: $0, coach: coach) }
        .sheet(item: $rollback) { CoachRollbackSheet(proposal: $0.proposal, diff: $0.diff, coach: coach) }
    }

    private func proposed(_ open: [CoachProposal], lastRun: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Proposed edits", systemImage: "lightbulb", count: open.count)
            if let snapshot = coach.proposals {
                if let error = snapshot.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
                }
                if snapshot.value != nil, open.isEmpty {
                    Text("No proposals — the coach looks once a week").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(open.enumerated()), id: \.element.id) { index, proposal in
                    CoachProposalCardView(proposal: proposal, isFirst: index == 0, coach: coach,
                                          actions: actions) { editing = proposal }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            CoachRunLineView(coach: coach, lastRun: lastRun)
        }
    }
}
