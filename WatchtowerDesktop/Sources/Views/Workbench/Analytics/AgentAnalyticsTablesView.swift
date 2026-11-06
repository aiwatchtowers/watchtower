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
/// time figures; a session whose calls had no price says "no price" (U4).
/// A pane too narrow for every column drops Started, Subagents and Branch.
struct AgentAnalyticsSessionsTable: View {
    let sessions: [AgentSessionRow]
    let actions: AgentAnalyticsActions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            AgentAnalyticsSessionRows(sessions: sessions, actions: actions, compact: false)
            AgentAnalyticsSessionRows(sessions: sessions, actions: actions, compact: true)
        }
    }
}

/// The sessions table in one width: every column, or (`compact`) the id,
/// Active and Cost only.
struct AgentAnalyticsSessionRows: View {
    let sessions: [AgentSessionRow]
    let actions: AgentAnalyticsActions
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.wide) {
                header("Session", width: ListLayout.textColumn)
                if !compact { header("Started", width: ListLayout.dateColumn) }
                header("Active", width: ListLayout.numberColumn, alignment: .trailing)
                header("Cost", width: ListLayout.numberColumn, alignment: .trailing)
                if !compact {
                    header("Subagents ∥", width: ListLayout.numberColumn, alignment: .trailing)
                    header("Branch", width: nil)
                }
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
            .frame(width: ListLayout.textColumn, alignment: .leading)
            if !compact {
                Text(AgentAnalyticsFormat.moment(session.startedAt))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: ListLayout.dateColumn, alignment: .leading)
            }
            cell(session.oldFormat ? "—" : AgentAnalyticsFormat.duration(session.activeMS))
            AgentSessionCostText(session: session)
                .frame(width: ListLayout.numberColumn, alignment: .trailing)
            if !compact {
                cell(session.oldFormat || session.avgParallel == 0 ? "—" : String(format: "%.1f", session.avgParallel))
                Text(session.oldFormat ? "older — time not analysed" : session.branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // A long branch truncates rather than pushing the pane to the compact rows.
                    .frame(minWidth: ListLayout.numberColumn, idealWidth: ListLayout.numberColumn,
                           maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
    }

    private func header(_ title: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minWidth: width ?? ListLayout.numberColumn, idealWidth: width ?? ListLayout.numberColumn,
                   maxWidth: width ?? .infinity, alignment: alignment)
    }

    private func cell(_ text: String) -> some View {
        Text(text).monospacedDigit().lineLimit(1).frame(width: ListLayout.numberColumn, alignment: .trailing)
    }
}

/// A session's cost: "$1.80", or "no price" in `.secondary` when its calls
/// had no price (U4).
struct AgentSessionCostText: View {
    let session: AgentSessionRow

    var body: some View {
        if AgentAnalyticsFormat.hasNoPrice(session) {
            Text(AgentAnalyticsFormat.noPrice)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Watchtower has no price for these calls; their tokens still count")
        } else {
            Text(AgentAnalyticsFormat.cost(session.costUSD)).monospacedDigit().lineLimit(1)
        }
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
