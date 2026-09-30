import CoreGraphics

/// A text column that fills its pane but never lets a line grow past a
/// readable length: on a wide pane the extra width becomes equal side
/// margins instead of longer lines. Pure.
package enum ReadableColumn {
    /// ~90 characters of 14 pt body text.
    package static let maxLineWidth: CGFloat = 760
    package static let minInset: CGFloat = 20

    /// The horizontal text inset for a pane `width` points wide.
    package static func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        max(minInset, ((width - maxLineWidth) / 2).rounded(.down))
    }
}
