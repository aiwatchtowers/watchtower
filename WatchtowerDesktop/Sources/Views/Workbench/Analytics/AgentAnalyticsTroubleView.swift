import SwiftUI
import WatchtowerCore

/// "Trouble": failed tool calls by error class (with the session that had
/// the most), denied calls, the owner's interrupts and rejections,
/// subagents that never finished and rate limits.
struct AgentAnalyticsTroubleView: View {
    let trouble: AgentTroubleReport?
    let actions: AgentAnalyticsActions

    var body: some View {
        AgentAnalyticsBlock(title: "Trouble", state: state) {
            if let trouble { measured(trouble) }
        }
    }

    private var state: AgentAnalyticsBlockState {
        guard let trouble else { return .notMeasured }
        let found = trouble.classes?.isEmpty == false || trouble.denials?.isEmpty == false
            || [trouble.interrupts, trouble.rejections, trouble.unfinishedSubagents, trouble.rateLimited]
            .contains { ($0 ?? 0) > 0 }
        return .make(factsSessions: trouble.factsSessions, hasFindings: found)
    }

    private func measured(_ trouble: AgentTroubleReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let classes = trouble.classes, !classes.isEmpty {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(classes.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            Text("\(row.class) · \(row.tool) — \(row.count)")
                            if let top = row.sessions.first {
                                AgentSessionLink(uuid: top.sessionUUID, actions: actions)
                            }
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            if let denials = trouble.denials, !denials.isEmpty {
                Text("Denied").font(.callout)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(denials.enumerated()), id: \.offset) { _, row in
                        Text("\(row.kind) · \([row.tool, row.target].filter { !$0.isEmpty }.joined(separator: " ")) — \(row.count)")
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                    }
                }
            }
            if (trouble.interrupts ?? 0) > 0 || (trouble.rejections ?? 0) > 0 {
                HStack(spacing: 6) {
                    Text("Interrupts: \(trouble.interrupts ?? 0) · rejections: \(trouble.rejections ?? 0)")
                    if let top = trouble.interruptSessions?.first {
                        AgentSessionLink(uuid: top.sessionUUID, actions: actions)
                    }
                }
                .font(.callout)
            }
            if let unfinished = trouble.unfinishedSubagents, unfinished > 0 {
                Text("Unfinished subagents: \(unfinished)").font(.callout)
            }
            if let limited = trouble.rateLimited, limited > 0 {
                Text("Rate limited: \(limited)").font(.callout)
            }
        }
    }
}
