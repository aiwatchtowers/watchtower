import Foundation

/// The editor panel's left side (spec A4): the editor chat, the form or the
/// whole recipe in Monaco. All three edit one draft.
package enum AutomationEditorMode: String, CaseIterable, Sendable {
    case chat, form, script

    /// The chat first; the form when the provider has no tools (Ollama),
    /// since the chat cannot draft there.
    package static func initial(toolsAvailable: Bool) -> Self {
        toolsAvailable ? .chat : .form
    }

    package var title: String {
        switch self {
        case .chat: "Chat"
        case .form: "Form"
        case .script: "Script"
        }
    }
}
