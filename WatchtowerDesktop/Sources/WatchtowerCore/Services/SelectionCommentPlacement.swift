import CoreGraphics

/// Where the floating "Comment" button sits next to a text selection
/// (Google Docs style): level with the selection's first line, just past its
/// trailing edge, kept inside the visible text area. Pure.
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
        let x = min(max(selection.maxX + gap, 0), maxX)
        let y = min(max(selection.minY, 0), maxY)
        return CGPoint(x: x, y: y)
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
