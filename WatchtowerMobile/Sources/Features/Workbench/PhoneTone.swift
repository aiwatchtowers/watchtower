import SwiftUI
import WatchtowerKit

/// Every colour the Workbench and Now screens draw (spec §14). Session tones
/// map exactly to `SessionStatePresentation.Tone`; `accent` is system blue.
/// Orange is for waiting-for-you and ask elements only.
enum PhoneTone: Equatable, Sendable {
    case green, orange, blue, red, secondary, accent

    /// The Mac's published tone; one from a newer Mac draws secondary.
    init(_ tone: TerminalSessionState.Tone) {
        switch tone {
        case .green: self = .green
        case .orange: self = .orange
        case .blue: self = .blue
        case .red: self = .red
        default: self = .secondary
        }
    }

    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .blue: .blue
        case .red: .red
        case .secondary: .secondary
        case .accent: .accentColor
        }
    }
}

/// One coloured element of a screen model: what the view paints and whether
/// it is a waiting-for-you or ask element (the only place orange may go).
struct ToneUse: Equatable {
    let element: String
    let tone: PhoneTone
    let isWaitingOrAsk: Bool
}

/// A short age: "now", "5m", "3h", "2d".
enum CompactAge {
    static func string(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

/// One session-state count with its dot (Workbench card, Now chips).
struct SessionStateCount: Equatable, Identifiable {
    let label: String
    let amount: Int
    let tone: PhoneTone
    /// Not-live states draw a ring, as a session row does.
    let isRing: Bool
    /// The waiting and needs-approval counts are waiting-for-you elements.
    let isWaiting: Bool

    var id: String { label }
    var text: String { "\(amount) \(label)" }

    /// The non-zero counts in a fixed order. "Not running" sessions are left
    /// out: they are old sessions, not state worth a dot.
    static func list(_ counts: Workbench.SessionCounts) -> [Self] {
        [
            Self(label: "working", amount: counts.working, tone: .green, isRing: false, isWaiting: false),
            Self(label: "waiting for you", amount: counts.waiting, tone: .orange, isRing: false, isWaiting: true),
            Self(label: "needs approval", amount: counts.needsApproval, tone: .orange, isRing: false, isWaiting: true),
            Self(label: "finished", amount: counts.finished, tone: .blue, isRing: true, isWaiting: false),
            Self(label: "failed", amount: counts.failed, tone: .red, isRing: true, isWaiting: false),
            Self(label: "stopped", amount: counts.stopped, tone: .secondary, isRing: true, isWaiting: false)
        ].filter { $0.amount > 0 }
    }

    static func sum(_ all: [Workbench.SessionCounts]) -> Workbench.SessionCounts {
        Workbench.SessionCounts(
            working: all.reduce(0) { $0 + $1.working },
            waiting: all.reduce(0) { $0 + $1.waiting },
            needsApproval: all.reduce(0) { $0 + $1.needsApproval },
            finished: all.reduce(0) { $0 + $1.finished },
            failed: all.reduce(0) { $0 + $1.failed },
            stopped: all.reduce(0) { $0 + $1.stopped },
            notRunning: all.reduce(0) { $0 + $1.notRunning }
        )
    }

    var toneUse: ToneUse {
        ToneUse(element: "session count \(label)", tone: tone, isWaitingOrAsk: isWaiting)
    }
}
