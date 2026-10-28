import SwiftUI
import WatchtowerCore

/// "Trouble": failed tool calls by error class (with the session that had
/// the most), denied calls, the owner's interrupts and rejections,
/// subagents that never finished and rate limits.
struct AgentAnalyticsTroubleView: View {
    let trouble: AgentTroubleReport?
    let actions: AgentAnalyticsActions

    var body: some View {
        AgentAnalyticsBlock(title: "Trouble", lead: trouble?.lead, state: state) {
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
        DisclosureGroup("Details") {
            details(trouble).padding(.top, Spacing.small)
        }
        .font(.callout)
    }

    private func details(_ trouble: AgentTroubleReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let classes = trouble.classes, !classes.isEmpty {
                LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(Array(classes.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: Spacing.compact) {
                            Text("\(AgentAnalyticsFormat.label(errorClass: row.class)) · \(AgentAnalyticsFormat.toolName(row.tool)) — \(row.count)")
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
                LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(Array(denials.enumerated()), id: \.offset) { _, row in
                        let what = [AgentAnalyticsFormat.toolName(row.tool), row.target].filter { !$0.isEmpty }.joined(separator: " ")
                        Text("\(AgentAnalyticsFormat.label(denial: row.kind)) · \(what) — \(row.count)")
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                    }
                }
            }
            if (trouble.interrupts ?? 0) > 0 || (trouble.rejections ?? 0) > 0 {
                HStack(spacing: Spacing.compact) {
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
