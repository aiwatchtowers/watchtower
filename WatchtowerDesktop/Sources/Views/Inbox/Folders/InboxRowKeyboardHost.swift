import SwiftUI
import WatchtowerCore

/// The keys on Waiting for me's and Mail waiting's rows, from the pane that
/// draws the artifact (`InboxReadingPane.rowKeyboard(_:)`): each press goes
/// where the row's own button sends it.
@MainActor
struct InboxRowKeys {
    /// The row's native actions as drawn now (`InboxRefHooks.content`); nil
    /// (a row the read does not list): only J/K.
    let content: (InboxRef) -> InboxRowActionsContent?
    /// A press through `InboxRowActionHandler`, as the row's button makes it.
    let press: (InboxRef, InboxRowPress) -> Void
    /// E on a sender: its Mark All Done…'s inline confirmation (`InboxBulkCenter.begin`).
    let beginBulk: (InboxBulkKey) -> Void
}

/// A key press the row's own actions carry out because it opens something
/// anchored to them: the Snooze menu, the Hand to Agent… picker. `serial`
/// tells two presses of the same key apart.
struct InboxRowKeyRequest: Equatable {
    enum Kind: Equatable { case snoozeMenu, handToAgent }

    let ref: InboxRef
    let kind: Kind
    let serial: Int
}

extension EnvironmentValues {
    /// Set by `InboxRowKeyboardHost` on the artifact it draws; read by
    /// `InboxRefRowActions` on the row it names.
    @Entry var inboxRowKeyRequest: InboxRowKeyRequest?
}

/// The artifact with a focused row: J/K move it over the shown rows (the
/// card's `ArtifactShownRefsKey`), the other keys go through
/// `InboxRowKeymap` to the focused row. The pane takes the keyboard on a
/// click or Tab; only then does a row show as focused.
struct InboxRowKeyboardHost<Content: View>: View {
    let keys: InboxRowKeys
    /// The card with the focused row (its `ArtifactEnvironment.focusedRef`).
    let content: (ArtifactRef?) -> Content

    @State private var shown: [ArtifactRef] = []
    @State private var focus = InboxRowFocus(refs: [])
    @State private var request: InboxRowKeyRequest?
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        ScrollViewReader { proxy in
            content(hasKeyboard ? focusedArtifactRef : nil)
                .environment(\.inboxRowKeyRequest, request)
                .onPreferenceChange(ArtifactShownRefsKey.self) { refs in
                    shown = refs
                    focus.reconcile(refs: refs.map(InboxRefHooks.inboxRef))
                }
                .focusable()
                .focusEffectDisabled()
                .focused($hasKeyboard)
                .onKeyPress(phases: .down) { handle($0, proxy) }
        }
    }

    private var focusedArtifactRef: ArtifactRef? {
        guard let focused = focus.focused else { return nil }
        return shown.first { InboxRefHooks.inboxRef($0) == focused }
    }

    private func handle(_ press: KeyPress, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.control, .option]), let ref = focus.focused else { return .ignored }
        let key = press.key == .return ? InboxRowKeymap.returnKey : press.characters.lowercased()
        let content = keys.content(ref)
        guard let command = InboxRowKeymap.command(
            key: key, command: press.modifiers.contains(.command), kind: ref.kind,
            canReply: content?.hasReply ?? false) else { return .ignored }
        switch command {
        case .moveDown, .moveUp:
            focus.move(command == .moveDown ? 1 : -1)
            if let target = focusedArtifactRef {
                withAnimation(Motion.toggle) { proxy.scrollTo(Optional(target)) }
            }
            return .handled
        default:
            break
        }
        guard let content, InboxRowKeymap.allows(command, content: content) else { return .ignored }
        switch command {
        case .openSnoozeMenu:
            request = InboxRowKeyRequest(ref: ref, kind: .snoozeMenu, serial: (request?.serial ?? 0) + 1)
        case .press(.handToAgent):
            request = InboxRowKeyRequest(ref: ref, kind: .handToAgent, serial: (request?.serial ?? 0) + 1)
        case .press(.markAllDone):
            keys.beginBulk(.sender(ref.key))
        case let .press(rowPress):
            keys.press(ref, rowPress)
        case .moveDown, .moveUp:
            break
        }
        return .handled
    }
}
