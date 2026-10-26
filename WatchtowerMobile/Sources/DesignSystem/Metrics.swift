import SwiftUI
// The scale tokens (`Spacing`, `Radius`, `Fill`, `ChipTint`, `Stroke`,
// `IconSize`, `Tracking`, `Motion`) and `Tone` come from the Kit's
// `WatchtowerDesign`, the one copy the Desktop's DesignKit reads too;
// re-exported here so every file of the app sees them. Only the phone's own
// additions live in this folder.
@_exported import WatchtowerDesign

/// A flat row's padding, and the `listRowInsets` around a card placed in a
/// `List`.
enum RowInsets {
    static let flat = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    static let card = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
}

/// The phone's own sizes, beside the shared tokens: the touch target and
/// the few fixed marks the mockups (`docs/design/mobile/mockups.html`) draw.
/// Parts read these instead of numbers.
enum PhoneMetrics {
    /// The smallest touch target (HIG).
    static let minTouch: CGFloat = 44
    /// A row's icon column and its state mark (mockup `.dot`).
    static let iconColumn: CGFloat = 20
    /// A progress step's icon column.
    static let stepColumn: CGFloat = 22
    /// A session's live dot (mockup `.dot.sm`).
    static let sessionDot: CGFloat = 10
    /// The state mark beside a state line (mockup 4).
    static let stateMark: CGFloat = 16
    /// The Mac chip's dot (mockup `.macchip i`).
    static let macDot: CGFloat = 7
    /// The priority dot of a meta line or chip.
    static let priorityDot: CGFloat = 6
    /// A bar's primary button (mockup `.primarybar .btn`).
    static let barButton: CGFloat = 46
    /// The small settings switch (mockup `.sw`).
    static let switchSize = CGSize(width: 42, height: 25)
    /// The app icon on Welcome.
    static let appIcon: CGFloat = 72
    /// A large status symbol on a full-screen outcome.
    static let outcomeSymbol: CGFloat = 48
    /// A thin progress bar.
    static let progressBar: CGFloat = 4
    /// The report's segmented bar (mockup 13 `.seg3`).
    static let segmentBar: CGFloat = 6
    /// A timeline row's time column and its dot (mockup 13 `.tl`).
    static let timeColumn: CGFloat = 48
    static let timelineDot: CGFloat = 8
    /// A review ask's document view scrolls inside its card between these.
    static let documentHeight: ClosedRange<CGFloat> = 320...480
}

/// The phone's view opacities: a closed card, a line not yet taken, a
/// pressed button. View dimming only; colour fills take `Fill`/`ChipTint`.
enum PhoneOpacity {
    /// A closed board card (the Desktop's 0.6).
    static let dimmed = 0.6
    /// An owner line still queued or waiting for the Mac (mockup `.queued`).
    static let pending = 0.75
    /// A live bar of the recorder's waveform.
    static let waveform = 0.85
    /// A button under the finger.
    static let pressed = 0.8
}
