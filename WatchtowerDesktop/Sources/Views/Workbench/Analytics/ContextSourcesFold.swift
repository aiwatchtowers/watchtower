import SwiftUI
import WatchtowerCore

/// **What's in it** (context actions, spec 2026-11-12 part 4): each part of
/// the start context opened into its source groups — the weight at start and
/// how often each was used. Built-in sources read "can't change"; a group no
/// session measured reads "not measured", never 0.
struct ContextSourcesFold: View {
    let sources: [AgentSourceGroupRow]
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
                ForEach(Array(Self.parts(sources).enumerated()), id: \.offset) { _, part in
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
    static func parts(_ sources: [AgentSourceGroupRow]) -> [Part] {
        let byPart = Dictionary(grouping: sources, by: \.part)
        let weight = { (rows: [AgentSourceGroupRow]) in rows.filter { $0.measuredSessions > 0 }.reduce(0) { $0 + $1.tokens } }
        let measured = { (rows: [AgentSourceGroupRow]) in rows.contains { $0.measuredSessions > 0 } }
        return byPart.sorted { a, b in
            let ka = (measured(a.value) ? 0 : 1, -weight(a.value)), kb = (measured(b.value) ? 0 : 1, -weight(b.value))
            return ka != kb ? ka < kb : a.key < b.key
        }
        .map { part, rows in
            let total = measured(rows) ? ContextActionsPresentation.tokens(weight(rows)) : notMeasured
            let sorted = rows.sorted { a, b in
                let ka = (a.measuredSessions > 0 ? 0 : 1, -a.tokens), kb = (b.measuredSessions > 0 ? 0 : 1, -b.tokens)
                return ka != kb ? ka < kb : name(a) < name(b)
            }
            return Part(title: "\(AgentAnalyticsFormat.label(part: part)) · \(total)", rows: sorted.map(row))
        }
    }

    static let notMeasured = "not measured"
    static let cantChange = "can't change"

    static func row(_ source: AgentSourceGroupRow) -> Row {
        let weight = source.measuredSessions > 0 ? ContextActionsPresentation.tokens(source.tokens) : notMeasured
        let fixed = source.groupKind == "builtin"
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
