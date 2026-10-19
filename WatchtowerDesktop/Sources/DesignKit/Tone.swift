import AppKit
import SwiftUI

/// The app's colours for status, priority and the few states every screen
/// shares (a warning, an all-clear, an error, the current moment).
public enum Tone {
    /// Maps `Target.statusColor`'s name to a colour; an unknown status is neutral.
    public static func status(_ name: String) -> Color {
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

    public static func priority(_ priority: String) -> Color {
        switch priority {
        case "high": .red
        case "low": .blue
        default: .orange
        }
    }

    /// A warning mark: a read that failed, a source to check.
    public static let warning: Color = .orange
    /// An all-clear check, a ready mark ("Prep ready").
    public static let success: Color = .green
    /// An inline error message.
    public static let error: Color = .red
    /// The current moment on a timeline (Home's NOW line, the meeting in progress).
    public static let now: Color = .orange

    /// Yellow that stays readable as chip text: system yellow in Dark,
    /// system brown (a dark mustard) in Light, where yellow text washes out.
    public static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : .systemBrown
    })
}
