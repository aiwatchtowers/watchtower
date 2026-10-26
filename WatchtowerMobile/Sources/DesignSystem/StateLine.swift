import SwiftUI

/// A session's one state line under its title (mockups 3, 4, 8): the state
/// mark (a glyph on a disc) or the live dot, the caption, and a time. A
/// working session counts up in m:ss (h:mm:ss past an hour) from
/// `stateAt`; a waiting one shows its age ("1m") with the caption in its
/// tone, semibold; with the Mac away (`asOf`, its last contact) the line is
/// "as of 12 min ago" and stops counting.
///
/// The model is built with `now`: the screen wraps the line in a
/// `TimelineView(.periodic(from: .now, by: 1))` to tick.
///
///     StateLine(model: StateLineModel(
///         glyph: session.stateGlyph, tone: PhoneTone(session.stateTone), isRing: session.isRing,
///         caption: session.stateCaption, isWaiting: isWaiting, stateAt: session.stateAt, now: context.date
///     ))
struct StateLineModel: Equatable {
    let glyph: String?
    let tone: PhoneTone
    let isRing: Bool
    let caption: String
    /// The state waits for the owner (an ask, an approval): the caption
    /// takes the tone and the time is an age.
    let isWaiting: Bool
    /// "3:14", "1m", "as of 12 min ago"; nil when `stateAt` is unknown.
    let time: String?

    init(
        glyph: String?,
        tone: PhoneTone,
        isRing: Bool = false,
        caption: String,
        isWaiting: Bool,
        stateAt: Date?,
        now: Date,
        asOf: Date? = nil
    ) {
        self.glyph = glyph.flatMap { $0.isEmpty ? nil : $0 }
        self.tone = tone
        self.isRing = isRing
        self.caption = caption
        self.isWaiting = isWaiting
        if let asOf {
            time = "as of \(LastSeen.phrase(asOf, now: now))"
        } else if let stateAt {
            time = isWaiting
                ? CompactAge.string(from: stateAt, now: now)
                : Self.timer(Int(now.timeIntervalSince(stateAt)))
        } else {
            time = nil
        }
    }

    /// The whole line as read: "Working · 3:14".
    var visibleText: String {
        time.map { "\(caption) · \($0)" } ?? caption
    }

    var toneUse: ToneUse {
        ToneUse(element: "state line", tone: tone, role: .session(isWaiting: isWaiting))
    }

    /// m:ss under an hour, h:mm:ss from there; a negative span is 0:00.
    static func timer(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let secs = String(format: "%02d", total % 60)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(secs)" : "\(minutes):\(secs)"
    }
}

struct StateLine: View {
    let model: StateLineModel

    var body: some View {
        // One Text, so a large text size wraps the line instead of cutting
        // the caption before the time.
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Group {
                if let glyph = model.glyph {
                    StateMark(glyph: glyph, tone: model.tone, size: PhoneMetrics.stateMark)
                } else {
                    SessionDot(tone: model.tone, isRing: model.isRing)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + $0.height / 4 }
            line
        }
        .font(.footnote)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.visibleText)
    }

    private var line: Text {
        let caption = Text(model.caption)
            .fontWeight(model.isWaiting ? .semibold : .regular)
            .foregroundStyle(model.isWaiting ? model.tone.color : Color.primary)
        guard let time = model.time else { return caption }
        return caption + Text(" · \(time)").monospacedDigit().foregroundStyle(.secondary)
    }
}

/// How long ago the Mac was last heard from: "just now", "12 min ago",
/// "3 h ago", "2 d ago". A date in the future is "just now".
enum LastSeen {
    static func phrase(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3_600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
