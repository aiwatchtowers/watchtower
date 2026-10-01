import CoreGraphics

/// Where a document's comment list sits when it is open: beside the text
/// when the pane is wide enough for both, otherwise below it — never on top
/// of the text (#180). Pure.
package enum CommentsPanelPlacement {
    package static let listWidth: CGFloat = 260
    package static let listHeight: CGFloat = 240
    /// The narrowest text column worth keeping beside the list.
    package static let minTextWidth: CGFloat = 300

    package static func besideText(width: CGFloat) -> Bool {
        width >= listWidth + minTextWidth
    }
}
