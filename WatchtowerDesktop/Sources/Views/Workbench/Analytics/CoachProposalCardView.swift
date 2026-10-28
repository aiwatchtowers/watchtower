import SwiftUI
import WatchtowerCore

/// What an evidence link does; the pane wires them to the page.
struct CoachActions {
    /// An ask id: the ask's drawer.
    let openAsk: (Int64) -> Void
    /// A session uuid: its analytics detail.
    let openSession: (String) -> Void
    /// A hint: the Statistics block.
    let scrollToStatistics: () -> Void
}

/// One open proposal: what it moves, why, the change, its evidence and the
/// owner's three verbs.
struct CoachProposalCardView: View {
    static let maxEvidence = 3
    static let maxDiffLines = 24

    let proposal: CoachProposal
    /// The pane's one prominent action is the first card's Accept.
    let isFirst: Bool
    let coach: CoachCenter
    let actions: CoachActions
    let onEdit: () -> Void
    @State private var confirmDecline = false

    static func metricLabel(_ metric: String) -> String {
        switch metric {
        case "corrections": "corrections"
        case "task_hours": "time per task"
        case "task_cost_usd": "cost per task"
        case "owner_loop": "you in the loop"
        case "spec_findings": "review findings"
        case "review_comments": "review comments"
        default: metric
        }
    }

    static func hasEdit(_ proposal: CoachProposal) -> Bool { proposal.destination != "claude_settings_allow" }

    var body: some View {
        // One LCS per render, not one per line.
        let diff = proposal.diffLines
        let busy = coach.pending.contains(proposal.id)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.compact) {
                Chip(text: "moves: \(Self.metricLabel(proposal.metric))", color: .blue)
                Chip(text: proposal.destinationLabel, color: .secondary)
            }
            Text(proposal.title).font(.headline)
            Text(proposal.why).font(.callout).foregroundStyle(.secondary)
            diffBlock(diff)
            if let error = coach.cardErrors[proposal.id] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning)
            }
            HStack(spacing: Spacing.regular) {
                evidence
                Spacer(minLength: Spacing.regular)
                Button("Decline") { confirmDecline = true }.buttonStyle(.kitSecondary)
                if Self.hasEdit(proposal) {
                    Button("Edit…", action: onEdit).buttonStyle(.kitSecondary)
                }
                acceptButton
            }
            .disabled(busy)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .confirmationDialog("Decline this proposal?", isPresented: $confirmDecline) {
            Button("Decline", role: .destructive) { Task { await coach.decline(proposal.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Decline for good? It will not be proposed again.")
        }
    }

    @ViewBuilder private var acceptButton: some View {
        if isFirst {
            Button("Accept") { Task { await coach.accept(proposal.id, editedText: nil) } }.buttonStyle(.kitPrimary)
        } else {
            Button("Accept") { Task { await coach.accept(proposal.id, editedText: nil) } }.buttonStyle(.kitSecondary)
        }
    }

    private func diffBlock(_ diff: [CoachDiffLine]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text([proposal.destinationLabel, proposal.sizeLine].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(diff.prefix(Self.maxDiffLines).enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
            if diff.count > Self.maxDiffLines {
                Text("+\(diff.count - Self.maxDiffLines) more lines").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    @ViewBuilder private func lineView(_ line: CoachDiffLine) -> some View {
        switch line {
        case let .kept(text):
            Text(text.isEmpty ? " " : text).font(.callout.monospaced()).foregroundStyle(.secondary)
        case let .removed(text):
            Text("− " + text).font(.callout.monospaced()).strikethrough().foregroundStyle(.secondary)
        case let .added(text):
            Text("+ " + text).font(.callout.monospaced()).foregroundStyle(Tone.success)
        }
    }

    /// "From ask #12 · a1b2c3d4 · +2": at most three links.
    @ViewBuilder private var evidence: some View {
        let items = proposal.evidence
        if !items.isEmpty {
            HStack(spacing: Spacing.compact) {
                Text("From").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(items.prefix(Self.maxEvidence).enumerated()), id: \.offset) { _, item in
                    evidenceLink(item)
                }
                if items.count > Self.maxEvidence {
                    Text("+\(items.count - Self.maxEvidence)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "ask:12#key" -> 12.
    static func askID(_ ref: String) -> Int64? {
        guard ref.hasPrefix("ask:") else { return nil }
        return Int64(ref.dropFirst(4).prefix { $0.isNumber })
    }

    @ViewBuilder private func evidenceLink(_ item: CoachEvidence) -> some View {
        switch item.kind {
        case "ask":
            if let id = Self.askID(item.ref) {
                Button("ask #\(id)") { actions.openAsk(id) }.buttonStyle(.link).font(.caption)
            }
        case "session":
            Button(String(item.ref.prefix(8))) { actions.openSession(item.ref) }.buttonStyle(.link).font(.caption)
        case "hint":
            Button("statistics") { actions.scrollToStatistics() }.buttonStyle(.link).font(.caption)
        default:
            Text(item.kind == "round" ? "review round" : item.kind).font(.caption).foregroundStyle(.secondary)
        }
    }
}
