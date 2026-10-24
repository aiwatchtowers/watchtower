import Foundation
import WatchtowerCore

/// A pane that can stand in for the Files pane as the place a code
/// navigation result lands — go to definition, Back/Forward, Open Quickly,
/// a Usages row (board #960, spec §2 "Where results land"). A Branch review
/// pane registers one for its workbench (`WorkbenchesViewModel
/// .registerDestination`); while it is the key pane, jumps go to it, and
/// otherwise they open the Files pane as before.
@MainActor
protocol CodeLocationDestination: AnyObject {
    /// The pane holds the keyboard focus in the window the owner works in.
    var isKeyDestination: Bool { get }
    /// The code root the pane's paths are relative to; nil = not known yet.
    /// Only a jump in this root is offered to it.
    var root: CodeRoot? { get }
    /// Puts `location` on screen. `location.line` 0 = no particular line
    /// (Open Quickly's pick of a file). false = not taken: Files opens it.
    func show(_ location: CodeNavLocation, root: CodeRoot) -> Bool
    /// Where the pane is, for the Back/Forward history; nil = not known.
    var currentLocation: CodeNavLocation? { get }
}

/// A registered destination, held weakly: the pane owns it.
struct WeakCodeLocationDestination {
    weak var destination: CodeLocationDestination?
}
