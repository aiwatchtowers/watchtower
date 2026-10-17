import Foundation

/// What ⌘/ does, decided from where the keyboard is. The menu equivalent
/// pre-empts the Files editor's own ⌘/ (toggle comment), so the editor case
/// is routed back to it.
enum HelpChatPolicy {
    enum Action: Equatable {
        case togglePopup, focusChatComposer, editorToggleComment
    }

    static func action(destination: SidebarDestination, editorHasKeyboard: Bool) -> Action {
        if destination == .chat { return .focusChatComposer }
        if editorHasKeyboard { return .editorToggleComment }
        return .togglePopup
    }
}
