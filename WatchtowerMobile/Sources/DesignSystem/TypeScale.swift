import SwiftUI

/// The Mac's type roles at iPhone sizes (design pass spec §2.8); everything
/// else uses system styles directly. Monospaced is only for counts, times,
/// keys and code; no role is uppercase. Meta lines use `.caption`, because
/// `.caption2` is too small for a whole line on a phone; `.caption2` stays
/// for badges and pills.
enum TypeScale {
    /// Detail headers: target, ask, event.
    static let screenTitle = Font.title3.weight(.semibold)
    /// Session title, Saved recording.
    static let pageTitle = Font.title2.weight(.semibold)
    /// Section labels, never uppercase.
    static let sectionHeader = Font.footnote.weight(.semibold)
    /// A flat row's title, a card's body text.
    static let rowTitle = Font.callout
    /// Workbench name, next-meeting title.
    static let rowEmphasis = Font.callout.weight(.semibold)
    /// Meta lines and captions.
    static let meta = Font.caption
    /// An ask's kind word, the REC mark.
    static let kind = Font.caption.weight(.semibold)
    static let badge = Font.caption2.weight(.semibold)
    static let pill = Font.caption2.weight(.medium)
    /// Times, ages, counts and percentages.
    static let time = Font.caption.monospacedDigit()
    /// Branch names and document paths only.
    static let code = Font.caption.monospaced()
}
