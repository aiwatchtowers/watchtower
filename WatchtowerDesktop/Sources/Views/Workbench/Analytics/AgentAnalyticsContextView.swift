import SwiftUI
import WatchtowerCore

/// "Context": what a session starts with (the baseline by part), what made
/// it grow (by source), the biggest sources, files read again and again,
/// compactions, and the instruction files' size on disk.
struct AgentAnalyticsContextView: View {
    let context: AgentContextReport?
    let actions: AgentAnalyticsActions

    var body: some View {
        AgentAnalyticsBlock(title: "Context", state: state) {
            if let context { measured(context) }
        }
    }

    private var state: AgentAnalyticsBlockState {
        let found = [
            context?.baseline?.parts?.isEmpty, context?.growth?.isEmpty,
            context?.topSources?.isEmpty, context?.repeatedReads?.isEmpty
        ].contains(false)
        return .make(factsSessions: context?.factsSessions, hasFindings: found)
    }

    private func measured(_ context: AgentContextReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let baseline = context.baseline, let parts = baseline.parts, !parts.isEmpty {
                Text("Baseline: \(AgentAnalyticsFormat.tokens(baseline.tokens ?? 0)) tokens at session start")
                    .font(.callout)
                AgentShareBar(parts: parts.map { ($0.part, $0.tokens, $0.share) })
            }
            if let growth = context.growth, !growth.isEmpty {
                Text("Growth by source").font(.callout)
                AgentShareBar(parts: growth.map { ($0.source, $0.tokens, $0.share) })
            }
            if let sources = context.topSources, !sources.isEmpty {
                Text("Top sources").font(.callout)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, row in
                        Text("\(row.tool) \(row.target) — \(AgentAnalyticsFormat.tokens(row.tokens)) tokens · "
                            + "\(row.calls) \(row.calls == 1 ? "call" : "calls") · "
                            + "\(row.sessions) \(row.sessions == 1 ? "session" : "sessions")")
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                    }
                }
            }
            if let reads = context.repeatedReads, !reads.isEmpty {
                Text("Read again and again").font(.callout)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(reads.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            Text("\(row.target) — \(row.reads) reads, \(AgentAnalyticsFormat.tokens(row.tokens)) tokens")
                                .lineLimit(1)
                            AgentSessionLink(uuid: row.sessionUUID, actions: actions)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            if let line = Self.compactionsLine(context.compactions) {
                Text(line).font(.callout)
            }
            if let line = Self.diskLine(context.disk) {
                Text(line).font(.caption).foregroundStyle(.secondary)
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

/// A titled v2 block: its content once measured, else one line saying why
/// there is none.
struct AgentAnalyticsBlock<Content: View>: View {
    let title: String
    let state: AgentAnalyticsBlockState
    @ViewBuilder let content: () -> Content

    var body: some View {
        AgentAnalyticsSection(title: title) {
            switch state {
            case .notMeasured:
                Text(AgentAnalyticsBlockState.notMeasuredLine).font(.callout).foregroundStyle(.secondary)
            case .nothingFound:
                Text("Nothing to fix here").font(.callout).foregroundStyle(.secondary)
            case .measured:
                content()
            }
        }
    }
}

/// A session's short id as a link to its analytics.
struct AgentSessionLink: View {
    let uuid: String
    let actions: AgentAnalyticsActions

    var body: some View {
        Button(String(uuid.prefix(8))) { actions.openSession(uuid) }
            .buttonStyle(.link)
            .font(.callout.monospaced())
            .help("Show this session's analytics")
    }
}

/// A stacked bar of shares with a legend line per part ("skills 900 · 10%").
struct AgentShareBar: View {
    let parts: [(label: String, tokens: Int64, share: Double)]

    private static let palette: [Color] = [.blue, .purple, .teal, .mint, .pink, .green, .indigo, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Rectangle()
                            .fill(Self.color(index))
                            .frame(width: max(proxy.size.width * min(max(part.share, 0), 1) - 1, 0))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(index)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("\(part.label) \(AgentAnalyticsFormat.tokens(part.tokens)) · "
                            + AgentAnalyticsFormat.percent(part.share, of: 1))
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    private static func color(_ index: Int) -> Color { palette[index % palette.count] }
}
