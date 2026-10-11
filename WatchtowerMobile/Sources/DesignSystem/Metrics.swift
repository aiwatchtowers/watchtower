import SwiftUI

/// The Mac's spacing steps (2/4/6/8/12/16) plus 20 for page margins in
/// full-screen layouts, the recorder and onboarding (design pass spec §2.9).
enum Spacing {
    static let tight: CGFloat = 2
    static let small: CGFloat = 4
    static let compact: CGFloat = 6
    static let regular: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let page: CGFloat = 20
}

/// One radius per role: an inner highlight, a row's selection fill, a card.
enum Radius {
    static let chip: CGFloat = 6
    static let row: CGFloat = 8
    static let card: CGFloat = 12
}

/// A flat row's padding, and the `listRowInsets` around a card placed in a
/// `List`.
enum RowInsets {
    static let flat = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    static let card = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
}
