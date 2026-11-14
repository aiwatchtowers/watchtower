import SwiftUI
import WatchtowerCore

/// **What's in it** (context actions, spec 2026-11-12 part 4): each part of
/// the start context opened into its source groups — the weight at start and
/// how often each was used. Built-in sources read "can't change"; a group no
/// session measured reads "not measured", never 0.
struct ContextSourcesFold: View {
    let sources: [AgentSourceGroupRow]
    /// The baseline bar's parts: a part's title shows the bar's total, and
    /// what its groups do not cover is one "not split by source" line.
    var parts: [AgentPartShare] = []
    @State var isExpanded = false

    struct Part: Equatable {
        let title: String
        let rows: [Row]
    }

    struct Row: Equatable {
        let name: String
        let detail: String
        /// A built-in source: drawn secondary.
        let fixed: Bool
    }

    var body: some View {
        DisclosureGroup("What's in it", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                ForEach(Array(Self.parts(sources, baseline: parts).enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(part.title).font(.callout.weight(.semibold).monospacedDigit())
                        ForEach(Array(part.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: Spacing.regular) {
                                Text(row.name).lineLimit(1)
                                Spacer(minLength: Spacing.regular)
                                Text(row.detail).monospacedDigit()
                            }
                            .font(.callout)
                            .foregroundStyle(row.fixed ? .secondary : .primary)
                        }
                    }
                }
            }
            .padding(Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
            .padding(.top, Spacing.small)
        }
        .font(.callout)
    }

    /// The parts, heaviest first, each with its groups heaviest first (a
    /// part no session measured last).
    /// Every part of the bar and every part with sources, heaviest first (a
    /// part nothing measured last). A part without sources (instructions,
    /// system) is its title alone, with the bar's total.
    static func parts(_ sources: [AgentSourceGroupRow], baseline: [AgentPartShare] = []) -> [Part] {
        let bar = Dictionary(baseline.map { ($0.part, Int($0.tokens)) }) { a, _ in a }
        let byPart = Dictionary(grouping: sources, by: \.part)
        let weight = { (rows: [AgentSourceGroupRow]) in rows.filter { $0.measuredSessions > 0 }.reduce(0) { $0 + $1.tokens } }
        let measured = { (part: String) in bar[part] != nil || byPart[part]?.contains { $0.measuredSessions > 0 } == true }
        let whole = { (part: String) in bar[part].map { max($0, weight(byPart[part] ?? [])) } }
        let size = { (part: String) in whole(part) ?? weight(byPart[part] ?? []) }
        let names = Set(bar.keys).union(byPart.keys)
        return names.sorted { a, b in
            let ka = (measured(a) ? 0 : 1, -size(a)), kb = (measured(b) ? 0 : 1, -size(b))
            return ka != kb ? ka < kb : a < b
        }
        .map { part in
            let rows = byPart[part] ?? []
            let split = weight(rows)
            let total = whole(part).map(ContextActionsPresentation.tokens)
                ?? (measured(part) ? ContextActionsPresentation.tokens(split) : notMeasured)
            let sorted = rows.sorted { a, b in
                let ka = (a.measuredSessions > 0 ? 0 : 1, -a.tokens), kb = (b.measuredSessions > 0 ? 0 : 1, -b.tokens)
                return ka != kb ? ka < kb : name(a) < name(b)
            }
            var lines = sorted.map(row)
            if !rows.isEmpty, let all = whole(part), all > split {
                lines.append(Row(name: notSplit, detail: ContextActionsPresentation.tokens(all - split), fixed: true))
            }
            return Part(title: "\(AgentAnalyticsFormat.label(part: part)) · \(total)", rows: lines)
        }
    }

    static let notMeasured = "not measured"
    /// The part's start weight its source groups do not account for.
    static let notSplit = "Not split by source"
    static let cantChange = "can't change"

    static func row(_ source: AgentSourceGroupRow) -> Row {
        let weight = source.measuredSessions > 0 ? ContextActionsPresentation.tokens(source.tokens) : notMeasured
        let fixed = source.groupKind == "builtin"
        // Server instructions are never called: their weight alone.
        guard source.part != "mcp" || fixed else { return Row(name: name(source), detail: weight, fixed: false) }
        let use = ["skills", "agents"].contains(source.part) ? "use" : "call"
        let usage = fixed ? cantChange : "\(source.calls) \(source.calls == 1 ? use : use + "s")"
        return Row(name: name(source), detail: "\(weight) · \(usage)", fixed: fixed)
    }

    static func name(_ source: AgentSourceGroupRow) -> String {
        switch source.groupKind {
        case "builtin": return "Built-in"
        case "claude_ai_connectors": return "claude.ai connectors"
        case "user" where source.group.isEmpty: return "Your own"
        case "project" where source.group.isEmpty: return "This project"
        default: return source.group.isEmpty ? source.groupKind : source.group
        }
    }
}
