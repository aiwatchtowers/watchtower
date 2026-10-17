import SwiftUI
import WatchtowerCore

/// The overview's tables: tasks, sessions, commands, and tokens & cost.
/// Plain grids with a header row; numbers right-aligned.

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

/// The period's sessions; a row opens the session's detail. An older
/// session has no time figures.
struct AgentAnalyticsSessionsTable: View {
    let sessions: [AgentSessionRow]
    let actions: AgentAnalyticsActions

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            AgentAnalyticsHeaderRow(titles: ["Session", "Started", "Active", "Cost", "Subagents ∥", "Branch"])
            ForEach(sessions, id: \.uuid) { session in
                GridRow {
                    Button(String(session.uuid.prefix(8))) { actions.openSession(session.uuid) }
                        .buttonStyle(.link)
                        .font(.callout.monospaced())
                        .help("Show this session's analytics")
                    Text(AgentAnalyticsFormat.moment(session.startedAt)).foregroundStyle(.secondary)
                    number(session.oldFormat ? "—" : AgentAnalyticsFormat.duration(session.activeMS))
                    number(AgentAnalyticsFormat.cost(session.costUSD))
                    number(session.oldFormat || session.avgParallel == 0 ? "—" : String(format: "%.1f", session.avgParallel))
                    Text(session.oldFormat ? "older — time not analysed" : session.branch)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
        VStack(alignment: .leading, spacing: 8) {
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
