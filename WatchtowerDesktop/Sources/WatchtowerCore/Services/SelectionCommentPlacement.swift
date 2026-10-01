import CoreGraphics

/// Where the floating "Comment" button sits next to a text selection
/// (Google Docs style), never on the selected text (#165): just past the
/// selection's trailing edge level with its first line when that fits, else
/// above the selection, else below it, flush with its trailing edge; only a
/// selection filling the whole view leaves it overlapping, at the top right.
/// Always inside the visible text area. Pure.
package enum SelectionCommentPlacement {
    package static let gap: CGFloat = 6

    /// - Parameters:
    ///   - selection: the selection's bounding box in the visible area's
    ///     coordinates (top-left origin), or nil when it is scrolled away.
    ///   - container: the visible area's size.
    ///   - button: the button's size.
    /// - Returns: the button's top-left corner, or nil when there is nothing
    ///   on screen to attach it to.
    package static func origin(selection: CGRect?, container: CGSize, button: CGSize) -> CGPoint? {
        guard let selection, !selection.isNull,
              selection.intersects(CGRect(origin: .zero, size: container)) else { return nil }
        let maxX = max(0, container.width - button.width - gap)
        let maxY = max(0, container.height - button.height)
        let clampedY = min(max(selection.minY, 0), maxY)
        if selection.maxX + gap <= maxX {
            return CGPoint(x: max(selection.maxX + gap, 0), y: clampedY)
        }
        let trailingX = min(max(selection.maxX - button.width, 0), maxX)
        let above = selection.minY - gap - button.height
        if above >= 0 { return CGPoint(x: trailingX, y: above) }
        let below = selection.maxY + gap
        if below <= maxY { return CGPoint(x: trailingX, y: below) }
        return CGPoint(x: maxX, y: clampedY)
    }
}

/// Whether a selection composer may save. It remembers the content id it
/// opened on: a re-render since then means its selection offsets point into
/// text that is gone, so saving is refused and the typed text kept. Pure.
package enum SelectionCommentCheck {
    package static let staleMessage = "The text changed — select the passage again."

    /// The refusal to show, or nil when the comment may be saved.
    package static func refusal(openedOn: String, current: String) -> String? {
        openedOn == current ? nil : staleMessage
    }
}
