import SwiftUI
import WatchtowerCore

// The overview's tables: tasks, sessions, commands, and tokens & cost.
// Plain grids with a header row (sessions as list rows); numbers
// right-aligned. Tasks and sessions show their first rows until Show all.

/// A long table's first `shown` rows, or all of them after "Show all N".
struct AgentAnalyticsTopRows<Row, Table: View>: View {
    let rows: [Row]
    let shown: Int
    @ViewBuilder let table: (_ rows: [Row]) -> Table
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            table(expanded ? rows : Array(rows.prefix(shown)))
            if rows.count > shown {
                Button(expanded ? "Show top \(shown)" : "Show all \(rows.count)") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

/// Per board target: calendar time, time in review, agent time and cost; a
/// row whose agent time was split with other targets says "shared". A row
/// opens its target on the Board.
struct AgentAnalyticsTasksTable: View {
    let tasks: [AgentTaskRow]
    let actions: AgentAnalyticsActions

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            AgentAnalyticsHeaderRow(titles: ["Task", "Calendar", "In review", "Agent", "Cost", ""])
            ForEach(tasks, id: \.targetID) { task in
                GridRow {
                    Button("#\(task.targetID) \(task.text)") { actions.openTarget(task.targetID) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help("Show #\(task.targetID) on the Board")
                    number(AgentAnalyticsFormat.duration(task.calendarMS))
                    number(AgentAnalyticsFormat.duration(task.phases["in_review"] ?? 0))
                    number(AgentAnalyticsFormat.duration(task.agentMS))
                    number(AgentAnalyticsFormat.cost(task.costUSD))
                    if task.shared {
                        Text("shared")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Another target was open in the same session at the same time; "
                                + "that stretch is split equally between them.")
                    } else {
                        Text("")
                    }
                }
            }
        }
    }
}

/// The period's sessions as list rows: the id (it opens the session's
/// detail) with its agent's tag, then the figures. An older session has no
/// time figures; a session whose model has no price says "no price" (U4).
struct AgentAnalyticsSessionsTable: View {
    let sessions: [AgentSessionRow]
    let actions: AgentAnalyticsActions

    /// Column widths shared by the header and the rows; Branch takes the rest.
    private enum Column {
        static let session: CGFloat = 180
        static let started: CGFloat = 120
        static let active: CGFloat = 64
        static let cost: CGFloat = 72
        static let parallel: CGFloat = 96
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.wide) {
                header("Session", width: Column.session)
                header("Started", width: Column.started)
                header("Active", width: Column.active, alignment: .trailing)
                header("Cost", width: Column.cost, alignment: .trailing)
                header("Subagents ∥", width: Column.parallel, alignment: .trailing)
                header("Branch", width: nil)
            }
            .padding(.horizontal, Spacing.regular)
            .padding(.bottom, Spacing.tight)
            ForEach(sessions, id: \.uuid) { session in
                row(session).kitRow(isSelected: false)
            }
        }
    }

    private func row(_ session: AgentSessionRow) -> some View {
        HStack(spacing: Spacing.wide) {
            HStack(spacing: Spacing.small) {
                Button(String(session.uuid.prefix(8))) { actions.openSession(session.uuid) }
                    .buttonStyle(.link)
                    .font(.callout.monospaced())
                    .help("Show this session's analytics")
                OutlineTag(text: AgentAnalyticsFormat.agentName(session))
            }
            .frame(width: Column.session, alignment: .leading)
            Text(AgentAnalyticsFormat.moment(session.startedAt))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Column.started, alignment: .leading)
            cell(session.oldFormat ? "—" : AgentAnalyticsFormat.duration(session.activeMS), width: Column.active)
            Group {
                if AgentAnalyticsFormat.hasNoPrice(session) {
                    Text(AgentAnalyticsFormat.noPrice).foregroundStyle(.secondary)
                        .help("Watchtower has no price for this model; its tokens still count")
                } else {
                    Text(AgentAnalyticsFormat.cost(session.costUSD)).monospacedDigit()
                }
            }
            .lineLimit(1)
            .frame(width: Column.cost, alignment: .trailing)
            cell(session.oldFormat || session.avgParallel == 0 ? "—" : String(format: "%.1f", session.avgParallel),
                 width: Column.parallel)
            Text(session.oldFormat ? "older — time not analysed" : session.branch)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func header(_ title: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minWidth: width ?? 0, maxWidth: width ?? .infinity, alignment: alignment)
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).monospacedDigit().lineLimit(1).frame(width: width, alignment: .trailing)
    }
}

/// Shell commands by verb: runs, failures, total and average time.
struct AgentAnalyticsCommandsTable: View {
    let commands: [AgentCommandRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            AgentAnalyticsHeaderRow(titles: ["Command", "Kind", "Runs", "Failed", "Total", "Average"])
            ForEach(commands, id: \.verb) { command in
                GridRow {
                    Text(command.verb).font(.callout.monospaced()).lineLimit(1)
                    Text(AgentToolClass.title(command.class)).foregroundStyle(.secondary)
                    number("\(command.runs)")
                    number("\(command.errors)")
                    number(AgentAnalyticsFormat.duration(command.totalMS))
                    number(AgentAnalyticsFormat.duration(command.avgMS))
                }
            }
        }
    }
}

/// Tokens and cost by model, main agent vs subagents, with each model's
/// cache read share, under the period's token totals.
struct AgentAnalyticsModelsTable: View {
    let models: [AgentModelRow]
    let tokens: AgentTokens

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(tokenLine).font(.caption).foregroundStyle(.secondary)
            if !models.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    AgentAnalyticsHeaderRow(titles: ["Model", "Main agent", "Subagents", "Tokens", "Cache read"])
                    ForEach(models, id: \.model) { model in
                        GridRow {
                            Text(model.model).font(.callout.monospaced()).lineLimit(1)
                            number(AgentAnalyticsFormat.cost(model.mainCostUSD))
                            number(AgentAnalyticsFormat.cost(model.subCostUSD))
                            number(model.tokens.formatted())
                            number(AgentAnalyticsFormat.percent(model.cacheReadShare, of: 1))
                        }
                    }
                }
            }
        }
    }

    private var tokenLine: String {
        let writes = tokens.cacheWrite5m + tokens.cacheWrite1h
        return "Tokens: \(tokens.input.formatted()) in · \(tokens.output.formatted()) out · "
            + "\(tokens.cacheRead.formatted()) cache read · \(writes.formatted()) cache write"
    }
}

/// A table's header row.
struct AgentAnalyticsHeaderRow: View {
    let titles: [String]

    var body: some View {
        GridRow {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A right-aligned number cell.
private func number(_ text: String) -> some View {
    Text(text).monospacedDigit().gridColumnAlignment(.trailing)
}
