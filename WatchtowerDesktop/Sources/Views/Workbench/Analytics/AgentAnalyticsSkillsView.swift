import SwiftUI
import WatchtowerCore

/// "Skills": how many listed skills ran and what the listing costs, the
/// skills by invocations (top 10, then Show all) and the ones never used.
struct AgentAnalyticsSkillsView: View {
    let skills: AgentSkillsReport?

    static let shownRows = 10

    var body: some View {
        AgentAnalyticsBlock(title: "Skills", lead: skills?.lead, state: state) {
            if let skills { measured(skills) }
        }
    }

    private var state: AgentAnalyticsBlockState {
        let found = skills?.rows?.isEmpty == false || skills?.neverUsed?.isEmpty == false
        return .make(factsSessions: skills?.factsSessions, hasFindings: found)
    }

    private func measured(_ skills: AgentSkillsReport) -> some View {
        let rows = skills.rows ?? []
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            // Without a lead from the report the plain count stands in for it.
            if (skills.lead ?? "").isEmpty { Text(Self.usedLine(skills)).font(.callout) }
            if !rows.isEmpty {
                DisclosureGroup("Used (\(rows.count))") {
                    AgentAnalyticsTopRows(rows: rows, shown: Self.shownRows) { rowList($0) }
                        .padding(.top, Spacing.small)
                }
                .font(.callout)
            }
            if let unused = skills.neverUsed, !unused.isEmpty {
                DisclosureGroup("Never used (\(unused.count))") {
                    LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(unused, id: \.name) { skill in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                                Text(skill.name).font(.callout.monospaced()).lineLimit(1)
                                Text("\(AgentAnalyticsFormat.tokens(skill.listingTokens)) tokens")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, Spacing.small)
                }
                .font(.callout)
                .help("Each listed skill costs its listing tokens in every session")
            }
        }
    }

    private func rowList(_ rows: [AgentSkillRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(rows, id: \.name) { row in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(row.name).font(.callout.monospaced()).lineLimit(1)
                    Text(Self.rowLine(row)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Used 1 of 5 listed skills · the listing costs 300 tokens per session".
    static func usedLine(_ skills: AgentSkillsReport) -> String {
        var line = "Used \(skills.used ?? 0) of \(skills.listed ?? 0) listed skills"
        if let tokens = skills.listingTokens, tokens > 0 {
            line += " · the listing costs \(AgentAnalyticsFormat.tokens(tokens)) tokens per session"
        }
        return line
    }

    /// "2 runs (slash 2) · $1.50 · 1 session".
    static func rowLine(_ row: AgentSkillRow) -> String {
        let triggers = row.byTrigger
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        var parts = ["\(row.invocations) \(row.invocations == 1 ? "run" : "runs")" + (triggers.isEmpty ? "" : " (\(triggers))")]
        parts.append(AgentAnalyticsFormat.cost(row.costUSD))
        parts.append("\(row.sessions) \(row.sessions == 1 ? "session" : "sessions")")
        return parts.joined(separator: " · ")
    }
}
