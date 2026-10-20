import SwiftUI
import WatchtowerCore

/// Home feed chip colours. They live in the app, not the kit, because they
/// read WatchtowerCore's feed types and the kit stays model-free.
extension Tone {
    /// A Home feed row's kind chip: one hue per source; a reminder is neutral.
    static func feedKind(_ kind: FeedKind) -> Color {
        switch kind {
        case .slack: .purple
        case .jira: .blue
        case .proposal: amber
        case .automation: .indigo
        case .reminder: .secondary
        case .target: .red
        case .email: .teal
        }
    }

    /// A Home feed event's chip: a meeting, a timed target or a reminder.
    static func feedEvent(_ ref: FeedRef) -> Color {
        switch ref {
        case .event: .green
        case .target: feedKind(.target)
        default: .secondary
        }
    }
}
