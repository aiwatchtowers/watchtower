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
