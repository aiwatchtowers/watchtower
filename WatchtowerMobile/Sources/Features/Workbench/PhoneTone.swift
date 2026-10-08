import SwiftUI
import UIKit
import WatchtowerKit

/// Every colour the Workbench and Now screens draw (spec §14). Session tones
/// map exactly to `SessionStatePresentation.Tone`; `accent` is system blue.
///
/// Orange is for waiting-for-you and ask elements only. This file is the
/// only place under `Sources/Features/` allowed to name it (SwiftLint
/// `orange_outside_phone_tone`): screens get it as `waitingForYou` or from
/// a session record's published tone.
enum PhoneTone: Equatable, Sendable {
    case green, orange, blue, red, secondary, accent

    /// The tone of every waiting-for-you and ask element.
    static let waitingForYou = Self.orange
    /// The tab bar's open-ask badge.
    static let waitingBadgeColor = UIColor.systemOrange

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

/// What a coloured element is, decided by the screen model from the data it
/// shows and independent of the tone it paints. Only waiting and ask
/// elements, and a session record in a waiting state, may be orange.
enum ToneRole: Equatable {
    case waiting
    case ask
    /// A session dot or label; `isWaiting` from the record's state kind and
    /// open asks, never from its tone.
    case session(isWaiting: Bool)
    case status
    case priority
    case progress
    case mac
    case info
}

/// One coloured element of a screen model: what the view paints and what it
/// is.
struct ToneUse: Equatable {
    let element: String
    let tone: PhoneTone
    let role: ToneRole

    var isWaitingOrAsk: Bool {
        switch role {
        case .waiting, .ask: true
        case let .session(isWaiting): isWaiting
        case .status, .priority, .progress, .mac, .info: false
        }
    }
}

/// A short age: "12s", "5m", "3h", "2d".
enum CompactAge {
    static func string(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
