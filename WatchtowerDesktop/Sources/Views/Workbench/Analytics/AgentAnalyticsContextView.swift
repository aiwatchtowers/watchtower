import SwiftUI
import WatchtowerCore

/// "Context": what a session starts with (the baseline by part), the ready
/// changes that would shrink it (**Do these**) and what is in it by source,
/// what made it grow (by source), the biggest sources, files read again and
/// again, compactions, and the instruction files' size on disk.
struct AgentAnalyticsContextView: View {
    let context: AgentContextReport?
    var codex: AgentAnalyticsCodexShare = .none
    let actions: AgentAnalyticsActions
    /// nil: no coach (analytics off, a test, a shot without it).
    var contextActions: ContextActionsInputs?
    /// What's in it starts open (a design shot); closed in the app.
    var sourcesExpanded = false

    @Environment(\.openURL) private var openURL
    @State private var rollback: CoachRollbackPrompt?

    static let shownGrowth = 6

    var body: some View {
        // While a session start waits to go live, redraw so the row leaves
        // "starting" when `CoachCenter.launchGrace` passes.
        if contextActions?.coach.hasLaunches == true {
            TimelineView(.periodic(from: .now, by: Self.launchRedraw)) { timeline in block(now: timeline.date) }
        } else {
            block(now: Date())
        }
    }

    static let launchRedraw: TimeInterval = 5

    private func block(now: Date) -> some View {
        let rows = context.flatMap { contextActions?.rows($0, now: now) } ?? (doThese: [], done: [])
        let baseline = Int(context?.baseline?.tokens ?? 0)
        let lead = context?.lead.map { Self.lead($0, baseline: baseline, rows: rows.doThese) }
        return AgentAnalyticsBlock(title: "Context", lead: lead, state: state, codex: codex) {
            if let context { measured(context, rows: rows) }
        } footer: {
            // Compactions and the files on disk show in any state.
            if let line = Self.compactionsLine(context?.compactions) {
                Text(line).font(.callout)
            }
            if let line = Self.diskLine(context?.disk) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The report's lead and "N changes would cut it to ~X." after it.
    static func lead(_ lead: String, baseline: Int, rows: [ContextActionRow]) -> String {
        let headline = ContextActionsPresentation.headline(baselineTokens: baseline, rows: rows)
        return headline.isEmpty ? lead : "\(lead) \(headline)."
    }

    private var state: AgentAnalyticsBlockState {
        let found = [
            context?.baseline?.parts?.isEmpty, context?.growth?.isEmpty,
            context?.topSources?.isEmpty, context?.repeatedReads?.isEmpty
        ].contains(false)
        return .make(factsSessions: context?.factsSessions, hasFindings: found)
    }

    private func measured(
        _ context: AgentContextReport, rows: (doThese: [ContextActionRow], done: [ContextActionRow])
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let baseline = context.baseline, let parts = baseline.parts, !parts.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Text("At session start · \(AgentAnalyticsFormat.tokens(baseline.tokens ?? 0))")
                        .font(.caption).foregroundStyle(.secondary)
                    AgentBaselineBar(parts: AgentBaselinePart.fold(parts))
                }
            }
            if let inputs = contextActions, !(rows.doThese.isEmpty && rows.done.isEmpty) {
                ContextActionsView(doThese: rows.doThese, done: rows.done, busy: inputs.coach.pending,
                                   errors: inputs.coach.cardErrors) { action, row in
                    inputs.perform(action, row, openURL: { openURL($0) }, rollback: { rollback = $0 })
                }
                .sheet(item: $rollback) { CoachRollbackSheet(proposal: $0.proposal, diff: $0.diff, coach: inputs.coach) }
            }
            if let sources = context.sources, !sources.isEmpty {
                ContextSourcesFold(sources: sources, parts: context.baseline?.parts ?? [], isExpanded: sourcesExpanded)
            }
            if let growth = context.growth, !growth.isEmpty { growthRows(growth) }
            if let sources = context.topSources, !sources.isEmpty {
                DisclosureGroup("Top sources") {
                    LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, row in
                            Text("\(AgentAnalyticsFormat.toolName(row.tool)) \(row.target) — "
                                + "\(AgentAnalyticsFormat.tokens(row.tokens)) tokens · "
                                + "\(row.calls) \(row.calls == 1 ? "call" : "calls") · "
                                + "\(row.sessions) \(row.sessions == 1 ? "session" : "sessions")")
                                .font(.callout.monospacedDigit())
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, Spacing.small)
                }
                .font(.callout)
            }
            if let reads = context.repeatedReads, !reads.isEmpty {
                DisclosureGroup("Read again and again") {
                    LazyVStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(Array(reads.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: Spacing.compact) {
                                Text("\(row.target) — \(row.reads) reads, \(AgentAnalyticsFormat.tokens(row.tokens)) tokens")
                                    .lineLimit(1)
                                AgentSessionLink(uuid: row.sessionUUID, actions: actions)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .padding(.top, Spacing.small)
                }
                .font(.callout)
            }
        }
    }

    /// The six largest growth sources as bar rows; the rest folded.
    private func growthRows(_ growth: [AgentGrowthRow]) -> some View {
        let sorted = growth.sorted { $0.tokens > $1.tokens }
        let (shown, rest) = AgentAnalyticsFormat.fold(sorted, keep: Self.shownGrowth)
        let largest = sorted.first?.tokens ?? 0
        let total = sorted.reduce(0) { $0 + $1.tokens }
        let row = { (item: AgentGrowthRow) in
            AgentGrowthRowView(name: AgentAnalyticsFormat.label(growthSource: item.source), tokens: item.tokens,
                               share: item.share, largest: largest)
        }
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("Growth during sessions · \(AgentAnalyticsFormat.tokens(total))")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in row(item) }
            }
            if !rest.isEmpty {
                DisclosureGroup("\(rest.count) more \(rest.count == 1 ? "source" : "sources") · "
                    + AgentAnalyticsFormat.tokens(rest.reduce(0) { $0 + $1.tokens })) {
                    LazyVStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(Array(rest.enumerated()), id: \.offset) { _, item in row(item) }
                    }
                    .padding(.top, Spacing.small)
                }
                .font(.callout)
            }
        }
    }

    /// "Compactions: 2 in 1 session · median 800 → 100 tokens"; nil with none.
    static func compactionsLine(_ stats: AgentCompactionStats?) -> String? {
        guard let stats, stats.count >= 1 else { return nil }
        return "Compactions: \(stats.count) in \(stats.sessions) \(stats.sessions == 1 ? "session" : "sessions") · "
            + "median \(AgentAnalyticsFormat.tokens(stats.medianPreTokens)) → "
            + "\(AgentAnalyticsFormat.tokens(stats.medianPostTokens)) tokens"
    }

    /// "CLAUDE.md: 60 lines, 2 KB · rules 10 bytes"; nil when neither exists.
    static func diskLine(_ disk: AgentDiskSizes?) -> String? {
        guard let disk, disk.claudeMDBytes > 0 || disk.rulesBytes > 0 else { return nil }
        let bytes = { (count: Int64) in ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
        var parts: [String] = []
        if disk.claudeMDBytes > 0 { parts.append("CLAUDE.md: \(disk.claudeMDLines) lines, \(bytes(disk.claudeMDBytes))") }
        if disk.rulesBytes > 0 { parts.append("rules \(bytes(disk.rulesBytes))") }
        return parts.joined(separator: " · ")
    }
}
