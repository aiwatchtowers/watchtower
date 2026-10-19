import AppKit
import SwiftUI
import WatchtowerCore

/// The app's colours for status, priority and the few states every screen
/// shares (a warning, an all-clear, an error, the current moment).
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

    /// A warning mark: a read that failed, a source to check.
    static let warning: Color = .orange
    /// An all-clear check, a ready mark ("Prep ready").
    static let success: Color = .green
    /// An inline error message.
    static let error: Color = .red
    /// The current moment on a timeline (Home's NOW line, the meeting in progress).
    static let now: Color = .orange

    /// A Home feed row's kind chip: one hue per source; a reminder is neutral.
    static func feedKind(_ kind: FeedKind) -> Color {
        switch kind {
        case .slack: .purple
        case .jira: .blue
        case .proposal: amber
        case .reminder: .secondary
        case .target: .red
        case .email: .teal
        }
    }

    /// Yellow that stays readable as chip text: system yellow in Dark,
    /// system brown (a dark mustard) in Light, where yellow text washes out.
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : .systemBrown
    })

    /// A Home feed event's chip: a meeting, a timed target or a reminder.
    static func feedEvent(_ ref: FeedRef) -> Color {
        switch ref {
        case .event: .green
        case .target: feedKind(.target)
        default: .secondary
        }
    }
}
