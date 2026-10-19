import SwiftUI
import WatchtowerCore

/// The hints in the report's order (ranked by their estimates in Go), each
/// with its own estimate — never a sum, as two hints can cite the same
/// time — its action line and fix button in sight, and a chevron to its
/// evidence. A target opens on the Board, a session opens its detail.
struct AgentAnalyticsHintsView: View {
    let hints: [AgentHint]
    let actions: AgentAnalyticsActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                VStack(alignment: .leading, spacing: Spacing.small) {
                    DisclosureGroup {
                        AgentHintEvidenceList(hint: hint, actions: actions)
                            .padding(.leading, Spacing.small)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                            Text(hint.finding).lineLimit(3)
                            Spacer(minLength: 8)
                            Text(Self.estimate(hint))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    AgentHintActionLine(hint: hint, actions: actions)
                        .padding(.leading, Spacing.large + Spacing.tight)
                }
            }
        }
    }

    /// The hint's own estimate: time when it has one, else money, else
    /// tokens. H3's is an upper bound.
    static func estimate(_ hint: AgentHint) -> String {
        let bound = hint.id == "H3" ? "≤ " : ""
        if hint.estimateMS > 0 { return bound + AgentAnalyticsFormat.duration(hint.estimateMS) }
        if hint.estimateUSD > 0 { return bound + AgentAnalyticsFormat.cost(hint.estimateUSD) }
        if let tokens = hint.estimateTokens, tokens > 0 { return "≈ \(AgentAnalyticsFormat.tokens(tokens)) tokens" }
        return ""
    }
}

/// "The main thing": the first hint as Go ranks it — its finding and
/// estimate, what to change, the fix button and its evidence under Where.
struct AgentAnalyticsMainThingCard: View {
    let hint: AgentHint
    let actions: AgentAnalyticsActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text("The main thing")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(AgentAnalyticsHintsView.estimate(hint))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(hint.finding).font(.body.weight(.medium))
            AgentHintActionLine(hint: hint, actions: actions)
            DisclosureGroup("Where") {
                AgentHintEvidenceList(hint: hint, actions: actions)
                    .padding(.leading, Spacing.small)
            }
            .font(.callout)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Fill.card))
    }
}

/// What to change and the button that does it; nothing from an older CLI.
struct AgentHintActionLine: View {
    let hint: AgentHint
    let actions: AgentAnalyticsActions

    var body: some View {
        let action = hint.action ?? ""
        if !action.isEmpty || AgentHintFixAction.make(hint.fix) != nil {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                if !action.isEmpty {
                    Text(action).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                AgentHintFixButton(fix: hint.fix, actions: actions)
            }
        }
    }
}

/// A hint's evidence, then "and N more" for what the report left out.
struct AgentHintEvidenceList: View {
    let hint: AgentHint
    let actions: AgentAnalyticsActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if hint.evidence.isEmpty, (hint.moreEvidence ?? 0) == 0 {
                Text("No evidence listed").foregroundStyle(.secondary)
            }
            ForEach(Array(hint.evidence.enumerated()), id: \.offset) { _, item in
                evidence(item)
            }
            if let more = hint.moreEvidence, more > 0 {
                Text("and \(more) more").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
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

/// The "What else would save" list: the first `limit` hints, then
/// "Show all N" / "Show fewer".
struct AgentAnalyticsCappedHints: View {
    static let limit = 5
    let hints: [AgentHint]
    let actions: AgentAnalyticsActions
    @State private var expanded = false

    /// The hints to render: all when expanded, else the first `limit`.
    static func visible(_ hints: [AgentHint], expanded: Bool, limit: Int = limit) -> [AgentHint] {
        expanded ? hints : Array(hints.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            AgentAnalyticsHintsView(hints: Self.visible(hints, expanded: expanded), actions: actions)
            if hints.count > Self.limit {
                Button(expanded ? "Show fewer" : "Show all \(hints.count)") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}
