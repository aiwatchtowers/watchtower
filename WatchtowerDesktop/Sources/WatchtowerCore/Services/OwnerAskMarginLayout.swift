import CoreGraphics

/// Where a review's margin comments go (spec 2026-10-03 Part 8): each card
/// beside the line its passage starts on, a card that would overlap the one
/// above pushed down below it. Without comments the margin takes no width.
/// Pure.
package enum OwnerAskMarginLayout {
    /// The gap between two cards.
    package static let spacing: CGFloat = 8
    package static let minWidth: CGFloat = 180
    package static let maxWidth: CGFloat = 260

    package struct Item: Equatable, Sendable {
        /// The top of the anchor's first line; nil when its passage is not
        /// in the text.
        package let anchorY: CGFloat?
        package let height: CGFloat

        package init(anchorY: CGFloat?, height: CGFloat) {
            self.anchorY = anchorY
            self.height = height
        }
    }

    /// The margin's width beside a review body `total` points wide.
    package static func width(total: CGFloat, comments: Int) -> CGFloat {
        guard comments > 0 else { return 0 }
        return min(max((total * 0.3).rounded(), minWidth), maxWidth)
    }

    /// Each item's top, in input order. Items are placed by their anchor
    /// (ties in input order); one without a place follows the rest.
    package static func tops(_ items: [Item]) -> [CGFloat] {
        let order = items.indices.sorted { lhs, rhs in
            switch (items[lhs].anchorY, items[rhs].anchorY) {
            case let (left?, right?): left != right ? left < right : lhs < rhs
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs < rhs
            }
        }
        var tops = [CGFloat](repeating: 0, count: items.count)
        var floor: CGFloat?
        for index in order {
            let wanted = items[index].anchorY ?? floor ?? 0
            let top = floor.map { max(wanted, $0) } ?? wanted
            tops[index] = top
            floor = top + items[index].height + spacing
        }
        return tops
    }
}
