import SwiftUI
import WatchtowerDesign

/// A drawn button's state as its host decides it (the Inbox card model's rules and the press's progress): disabled
/// with a label of its own ("Chat — on your Mac"), busy with its line ("Approving…"), or refused with its sentence.
struct PhoneArtifactButtonState: Equatable {
    var enabled = true
    /// Drawn in place of the button's own label.
    var label: String?
    /// While the press runs: a spinner and this line in place of the label.
    var busyLabel: String?
    /// The line drawn under the buttons ("Didn't finish", a refusal).
    var note: String?
}

/// One entry of a ref row's context menu: a verb, a submenu (Snooze ▸), or a line that says why the rest are not
/// here.
struct PhoneMenuEntry: Identifiable {
    let title: String
    var enabled = true
    var children: [Self] = []
    var action: () -> Void = {}

    var id: String { title }
}

/// What a host does with a ref row it draws (mobile Inbox spec §7, mockup §2): the swipes, the context menu (the
/// full verb set and the accessibility path), the press in flight or its refusal with Retry, a time on the right
/// (a plan item's, in the phone's zone), and whether the row is hidden (closed, or hidden on `ok`).
struct PhoneRefRowActions {
    var hidden = false
    var leading: [SwipeAction] = []
    var trailing: [SwipeAction] = []
    var menu: [PhoneMenuEntry] = []
    var busyLabel: String?
    var error: String?
    /// The refusal's button (Retry) and what it does.
    var retry: (title: String, action: () -> Void)?
    var trailingText: String?
    /// Buttons drawn under the row, which then sits on a waiting card (an idea to judge, mockup §5); the first is
    /// the primary one.
    var inline: [PhoneMenuEntry] = []
    /// The tour's swiped frame.
    var revealed: HorizontalEdge?
}

/// The host's side of `PhoneArtifactView`: each button's state by its press address, and each ref row's actions.
/// The default draws every button enabled and every row as the document has it.
struct PhoneArtifactInputs {
    var buttonState: (Int) -> PhoneArtifactButtonState = { _ in PhoneArtifactButtonState() }
    var refRow: (ArtifactRef) -> PhoneRefRowActions = { _ in PhoneRefRowActions() }
}

extension EnvironmentValues {
    /// Set by the Inbox's card screen around `PhoneArtifactView`.
    @Entry var phoneArtifactInputs = PhoneArtifactInputs()
}

/// A ref row's context menu entries as SwiftUI menu items.
struct PhoneMenuItems: View {
    let entries: [PhoneMenuEntry]

    var body: some View {
        ForEach(entries) { entry in
            if !entry.children.isEmpty {
                Menu(entry.title) { Self(entries: entry.children) }
            } else {
                Button(entry.title, action: entry.action).disabled(!entry.enabled)
            }
        }
    }
}
