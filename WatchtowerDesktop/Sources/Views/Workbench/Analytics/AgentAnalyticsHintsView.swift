import SwiftUI
import WatchtowerCore

/// "What would save the most": the hints in the report's order (ranked by
/// their estimates in Go), each with its own estimate — never a sum, as
/// two hints can cite the same time — and expandable to its evidence. A
/// target opens on the Board, a session opens its detail.
struct AgentAnalyticsHintsView: View {
    let hints: [AgentHint]
    let actions: AgentAnalyticsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        if hint.evidence.isEmpty {
                            Text("No evidence listed").foregroundStyle(.secondary)
                        }
                        ForEach(Array(hint.evidence.enumerated()), id: \.offset) { _, item in
                            evidence(item)
                        }
                    }
                    .font(.callout)
                    .padding(.leading, 4)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(hint.finding).lineLimit(3)
                        Spacer(minLength: 8)
                        Text(Self.estimate(hint))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The hint's own estimate: time when it has one, else money. H3's is
    /// an upper bound.
    static func estimate(_ hint: AgentHint) -> String {
        let bound = hint.id == "H3" ? "≤ " : ""
        if hint.estimateMS > 0 { return bound + AgentAnalyticsFormat.duration(hint.estimateMS) }
        if hint.estimateUSD > 0 { return bound + AgentAnalyticsFormat.cost(hint.estimateUSD) }
        return ""
    }

    @ViewBuilder
    private func evidence(_ item: AgentHintEvidence) -> some View {
        switch item.kind {
        case "target":
            if let id = Int64(item.ref.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) {
                Button("\(item.ref) \(item.label)") { actions.openTarget(id) }
                    .buttonStyle(.link)
                    .help("Show \(item.ref) on the Board")
            } else {
                Text("\(item.ref) \(item.label)")
            }
        case "session":
            Button("Session \(item.label)") { actions.openSession(item.ref) }
                .buttonStyle(.link)
                .help("Show this session's analytics")
        default:
            Text("\(item.ref) — \(item.label)")
        }
    }
}
