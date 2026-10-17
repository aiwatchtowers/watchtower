import Charts
import SwiftUI
import WatchtowerCore

/// The time categories' names and colours — the one place both are set
/// (the breakdown bar, its legend and the session timeline). System
/// colours, so each has its own light and dark shade.
extension AgentTimeCategory {
    var title: String {
        switch self {
        case .model: "Model"
        case .tool: "Tools"
        case .background: "Background agents"
        case .owner: "You"
        case .away: "Away"
        }
    }

    var color: Color {
        switch self {
        case .model: .purple
        case .tool: .blue
        case .background: .teal
        case .owner: .brown
        case .away: .gray
        }
    }
}

/// The tool classes' names (`AgentToolTimes`, `AgentSegment.toolClass`).
enum AgentToolClass {
    static func title(_ raw: String) -> String {
        switch raw {
        case "build_test": "build & test"
        case "git": "git"
        case "read_search": "read & search"
        case "edit": "edit"
        case "mcp": "MCP"
        case "subagents_fg": "subagents (fg)"
        case "other": "other"
        default: raw
        }
    }

    /// The classes with their time, longest first; a class with none is left out.
    static func parts(_ tools: AgentToolTimes) -> [(raw: String, ms: Int64)] {
        let all: [(String, Int64)] = [
            ("build_test", tools.buildTest), ("git", tools.git), ("read_search", tools.readSearch),
            ("edit", tools.edit), ("mcp", tools.mcp), ("subagents_fg", tools.subagentsFG), ("other", tools.other)
        ]
        return all.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { (raw: $0.0, ms: $0.1) }
    }

    static func total(_ tools: AgentToolTimes) -> Int64 {
        tools.buildTest + tools.git + tools.readSearch + tools.edit + tools.mcp + tools.subagentsFG + tools.other
    }
}

/// "Where the time went": the stacked bar over active time, its legend
/// with shares, the tool classes' sub-line and the permission-prompt note.
struct AgentTimeBreakdownView: View {
    let time: AgentTimeSplit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentAnalyticsTimeBar(time: time)
            HStack(spacing: 12) {
                ForEach(AgentAnalyticsTimeBar.parts(time), id: \.category) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.category.color).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("\(part.category.title) \(share(part.ms))")
                    }
                }
            }
            .font(.callout)
            if !toolLine.isEmpty {
                Text(toolLine).font(.caption).foregroundStyle(.secondary)
            }
            Text("Tool time includes permission prompts.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var toolLine: String {
        AgentToolClass.parts(time.tools)
            .map { "\(AgentToolClass.title($0.raw)) \(share($0.ms))" }
            .joined(separator: " · ")
    }

    private func share(_ ms: Int64) -> String {
        AgentAnalyticsFormat.percent(Double(ms), of: Double(time.activeMS))
    }
}

/// The stacked bar: Tools, Model, Background agents and You over active
/// time (away is left out, as from active time).
struct AgentAnalyticsTimeBar: View {
    struct Part {
        let category: AgentTimeCategory
        let ms: Int64
    }

    let time: AgentTimeSplit

    static func parts(_ time: AgentTimeSplit) -> [Part] {
        [
            Part(category: .tool, ms: AgentToolClass.total(time.tools)),
            Part(category: .model, ms: time.modelMS),
            Part(category: .background, ms: time.backgroundMS),
            Part(category: .owner, ms: time.ownerMS)
        ]
    }

    var body: some View {
        AgentChartHost {
            chart
        }
        .frame(height: 18)
    }

    private var chart: some View {
        Chart(Self.parts(time), id: \.category) { part in
            BarMark(x: .value("Time", part.ms), y: .value("Period", "all"))
                .foregroundStyle(part.category.color)
                .accessibilityLabel(part.category.title)
                .accessibilityValue(AgentAnalyticsFormat.duration(part.ms))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(range: .plotDimension(padding: 0))
    }
}

/// Builds a Swift Charts chart only once its place is on screen: `Chart`
/// traps when its body is evaluated outside a hosted view tree, which is
/// what view inspection does. Until then the place stays empty.
struct AgentChartHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var onScreen = false

    var body: some View {
        Group {
            if onScreen {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear { onScreen = true }
    }
}
