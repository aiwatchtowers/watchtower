import SwiftUI
import WatchtowerCore

/// Home's Workbench zone: per workbench, the live sessions to look at (state
/// dot and caption from `SessionStatePresentation`) and the open asks, then
/// the coach's newest open proposal as the last row. A failed read says so.
struct WorkbenchZoneView: View {
    let blocks: [HomeWorkbenchBlock]
    let coach: HomeCoachProposal?
    let failed: Bool
    let onLink: (HomeLink) -> Void
    /// Accept (true) / Decline (false) the proposal; the line to show, nil on success.
    let onDecideCoach: (Int64, Bool) async -> String?
    /// Open the proposal in this workbench's Analytics pane.
    let onOpenCoach: (Int64) -> Void
    /// `HomeCenter.coachNote`: shown where the row sits, with or without one.
    var coachNote: String?

    var body: some View {
        HomeZone(title: "Workbench") {
            Button("Open →") { onLink(.workbenches) }
        } content: {
            if failed {
                HomeZoneErrorLine(zone: "Workbench")
            }
            // Space, not dividers, separates the blocks and the coach row.
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(blocks, id: \.workbenchID) { block in
                    WorkbenchBlockView(block: block, onLink: onLink)
                }
                if let coach {
                    HomeCoachRow(coach: coach, onDecide: onDecideCoach, onOpen: onOpenCoach)
                        .id(coach.proposal.id)
                }
                if let coachNote {
                    Text(coachNote).font(.caption).foregroundStyle(Tone.warning).homeZoneInset()
                }
            }
        }
    }
}

/// One workbench: its name with the session count, its session rows, then
/// its ask rows.
private struct WorkbenchBlockView: View {
    let block: HomeWorkbenchBlock
    let onLink: (HomeLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(block.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: Spacing.regular)
                if !block.sessions.isEmpty {
                    Text(Self.sessionCount(block.sessions.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .homeZoneInset()
            .padding(.bottom, Spacing.tight)
            ForEach(block.sessions, id: \.sessionID) { status in
                sessionRow(status)
            }
            ForEach(block.asks, id: \.ask.id) { row in
                askRow(row)
            }
        }
    }

    /// "1 session", "2 sessions".
    static func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    @ViewBuilder private func sessionRow(_ status: SessionAgentStatus) -> some View {
        let tone = SessionStatePresentation.color(for: status.state).color
        Button {
            if let link = HomeWorkbenchBuilder.link(for: status) { onLink(link) }
        } label: {
            HStack(spacing: Spacing.regular) {
                HomeStatusDot(color: tone)
                Text(status.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Spacing.regular)
                Text(SessionStatePresentation.caption(for: status.state))
                    .font(.caption)
                    .foregroundStyle(tone)
                    .lineLimit(1)
            }
            .kitRow(isSelected: false)
        }
        .buttonStyle(.plain)
    }

    private func askRow(_ row: WorkbenchAskRow) -> some View {
        Button { onLink(HomeWorkbenchBuilder.link(for: row)) } label: {
            HStack(spacing: Spacing.regular) {
                Chip(text: row.ask.kind.rawValue.capitalized, color: .secondary)
                Text(row.ask.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            // Under its workbench's sessions, past their status dots.
            .padding(.leading, Spacing.large)
            .kitRow(isSelected: false)
        }
        .buttonStyle(.plain)
    }
}

/// The coach's newest open proposal: where it goes, the title, the changed
/// lines (at most 4), and Open in Analytics / Decline / Accept through the
/// coach CLI. A change over 4 lines shows its first 4 and "…", and only
/// Open in Analytics and Decline: it is read in full in the pane first.
private struct HomeCoachRow: View {
    let coach: HomeCoachProposal
    let onDecide: (Int64, Bool) async -> String?
    let onOpen: (Int64) -> Void
    @State private var busy = false
    @State private var note: String?
    @State private var confirmDecline = false

    var body: some View {
        let proposal = coach.proposal
        let preview = CoachHomeRow.lines(proposal)
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(Self.header(proposal))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(proposal.title)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Array(preview.shown.enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
                if preview.truncated {
                    Text("…").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(Tone.warning)
            }
            HStack(spacing: Spacing.small) {
                Button("Open in Analytics") { onOpen(coach.targetWorkbench) }
                    .buttonStyle(.kitQuiet)
                Spacer(minLength: Spacing.regular)
                Button("Decline") { confirmDecline = true }
                    .buttonStyle(.kitQuiet)
                    .disabled(busy)
                if !preview.truncated {
                    Button("Accept") { decide(accept: true) }
                        .buttonStyle(.kitPrimary)
                        .disabled(busy)
                }
            }
            .controlSize(.small)
        }
        .homeZoneInset()
        .confirmationDialog("Decline this proposal?", isPresented: $confirmDecline) {
            Button("Decline", role: .destructive) { decide(accept: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Decline for good? It will not be proposed again.")
        }
    }

    /// "Coach suggests · Session instructions · all workbenches".
    static func header(_ proposal: CoachProposal) -> String {
        "Coach suggests · \(proposal.destinationLabel)"
    }

    @ViewBuilder private func diffLine(_ line: CoachDiffLine) -> some View {
        switch line {
        case let .added(text): diffText("+ \(text)", Tone.success)
        case let .removed(text): diffText("\u{2212} \(text)", Tone.error)
        case .kept: EmptyView()
        }
    }

    private func diffText(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func decide(accept: Bool) {
        busy = true
        note = nil
        Task {
            let line = await onDecide(coach.proposal.id, accept)
            note = line
            // The re-read replaces or removes the row; a failure keeps it usable.
            busy = false
        }
    }
}
