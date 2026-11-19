import AppKit
import SwiftUI
import WatchtowerCore

/// "Accepted edits": accepted and rolled-back proposals, newest first. A
/// pull-request edit links its PR (and its revert PR); the list reads the
/// PRs' state from GitHub once when it appears (`coach sync-prs`, spec
/// 2026-11-19 §4.4).
struct CoachAcceptedLogView: View {
    static let collapsedCount = 10

    let accepted: [CoachProposal]
    let open: [CoachProposal]
    let coach: CoachCenter
    let onRollback: (CoachProposal) -> Void
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Accepted edits", systemImage: "checkmark.circle", count: accepted.count)
            if let line = coach.syncLine {
                Label { Text(CoachPRTexts.styled(line)) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
            }
            if accepted.isEmpty {
                Text("Nothing accepted yet").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(showAll ? accepted : Array(accepted.prefix(Self.collapsedCount))) { row($0) }
                }
                if accepted.count > Self.collapsedCount {
                    Button(showAll ? "Show fewer" : "Show all \(accepted.count)") { showAll.toggle() }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                }
            }
        }
        .onAppear { coach.syncPRs() }
    }

    static func tone(_ p: CoachProposal) -> Color {
        if p.status == "rolled_back" { return .secondary }
        switch p.verdict {
        case "works": return Tone.success
        case "no_effect": return .secondary
        default: return Tone.warning
        }
    }

    private func row(_ p: CoachProposal) -> some View {
        let hasCut = open.contains { $0.revertsID == p.id }
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.regular) {
                Circle()
                    .fill(Self.tone(p))
                    .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                    .accessibilityHidden(true)
                Text(Self.date(p.decidedAt)).font(.caption.weight(.semibold).monospacedDigit())
                Text(p.title).font(.callout).lineLimit(1)
                Spacer(minLength: Spacing.regular)
                if let url = URL(string: p.prURL), !p.prURL.isEmpty {
                    CoachPRLink(label: p.prLabel, url: url).font(.caption)
                }
                Text(p.verdictLine(hasCut: hasCut, now: Date(), writtenPath: coach.written[p.id]?.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if p.status == "accepted" {
                    Button("Roll Back") { onRollback(p) }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                        .disabled(coach.pending.contains(p.id))
                }
            }
            if p.revertLine != nil, let url = URL(string: p.revertPRURL) {
                HStack(spacing: Spacing.compact) {
                    Text(CoachPRTexts.revertLead)
                    CoachPRLink(label: CoachPRTexts.label(p.revertPRURL), url: url)
                    Text(CoachPRTexts.revertTail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, IconSize.stateDot + Spacing.regular)
            }
            if let error = coach.cardErrors[p.id] {
                HStack(spacing: Spacing.regular) {
                    Text(CoachPRTexts.styled(error)).font(.caption).foregroundStyle(Tone.warning)
                    if coach.retries[p.id] == .rollback {
                        Button(CoachPRTexts.retry) { onRollback(p) }
                            .buttonStyle(.kitQuiet)
                            .controlSize(.small)
                            .disabled(coach.pending.contains(p.id))
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.regular)
        .frame(minHeight: ListLayout.rowMinHeight)
        .kitRow(isSelected: false)
    }

    static func date(_ raw: String?, timeZone: TimeZone = .current) -> String {
        guard let raw, let d = AgentAnalyticsFormat.reportDate(raw) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

/// "PR #12": opens the pull request in the browser; the caller sets the font.
struct CoachPRLink: View {
    let label: String
    let url: URL

    var body: some View {
        Button(label) { NSWorkspace.shared.open(url) }
            .buttonStyle(.link)
            .help(url.absoluteString)
    }
}
