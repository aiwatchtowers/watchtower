import SwiftUI

/// The Targets tab's colours for status and priority.
enum Tone {
    /// Maps `Target.statusColor`'s name to a colour; an unknown status is neutral.
    static func status(_ name: String) -> Color {
        switch name {
        case "blue": .blue
        case "teal": .teal
        case "red": .red
        case "green": .green
        case "gray": .gray
        case "purple": .purple
        default: .secondary
        }
    }

    static func priority(_ priority: String) -> Color {
        switch priority {
        case "high": .red
        case "low": .blue
        default: .orange
        }
    }
}
