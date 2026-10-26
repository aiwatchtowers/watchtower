import Foundation

/// One piece of a switcher row's state text, under the name: what it says
/// and how it is drawn. Shared by the workbench switcher (and the go-to
/// palette's workbench rows) and the Chats project switcher, so each builds
/// its segments in pure code and the one `SwitcherStateSegments` view draws
/// them.
package struct SwitcherSegment: Equatable, Sendable {
    /// How a segment is drawn: a blue count badge, orange text, grey text.
    package enum Tone: Equatable, Sendable {
        case badge
        case warning
        case secondary
    }

    package let text: String
    package let tone: Tone

    package init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

extension WorkbenchSwitcherPresentation.Segment {
    /// The neutral segment this workbench segment draws as: new comments
    /// as the badge, blocked in orange, working sessions and the age grey.
    package var switcherSegment: SwitcherSegment {
        let tone: SwitcherSegment.Tone = switch self.tone {
        case .comments: .badge
        case .blocked: .warning
        case .sessions, .age: .secondary
        }
        return SwitcherSegment(text: text, tone: tone)
    }
}
