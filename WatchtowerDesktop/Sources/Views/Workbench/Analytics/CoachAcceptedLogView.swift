import SwiftUI
import WatchtowerCore

/// "Accepted edits": accepted and rolled-back proposals, newest first.
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
                Text(p.verdictLine(hasCut: hasCut, now: Date())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if p.status == "accepted" {
                    Button("Roll Back") { onRollback(p) }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                        .disabled(coach.pending.contains(p.id))
                }
            }
            if let error = coach.cardErrors[p.id] {
                Text(error).font(.caption).foregroundStyle(Tone.warning)
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
