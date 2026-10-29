import SwiftUI

/// The baseline parts' colours, fixed by the part's key (not its rank), so a
/// part keeps its colour from one period to the next. System colours, so
/// each adapts to light and dark.
enum AgentAnalyticsPalette {
    static func color(forPart key: String) -> Color {
        switch key {
        case "tools": .blue
        case "instructions": .purple
        case "skills": .cyan
        case "system": .green
        case "hooks": .orange
        case "deferred_tools": .mint
        case "agents": .indigo
        case "mcp": .teal
        default: .gray
        }
    }

    /// The "N more" remainder.
    static let rest: Color = .gray
}
