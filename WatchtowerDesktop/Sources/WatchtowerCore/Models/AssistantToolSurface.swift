import Foundation

/// Human labels for the tool registry's surface ids (`Tool.Surfaces` in
/// `internal/tools/`), shown on Settings → Assistant tools.
package enum AssistantToolSurface {
    /// `tools.WorkbenchSurface`: its write tools always apply in their own
    /// workbench (DEV-06) and never read trust, so it is no trust place.
    package static let workbench = "project"

    /// `tools.ChatSurfaces()`: the surfaces a chat's tool mode binds to, in
    /// the order pinned by `internal/tools/testdata/chat_surfaces.txt`.
    package static let chatSurfaces = ["main", "target", "automation_editor", "tuning"]

    package static func label(for surface: String) -> String {
        switch surface {
        case "main": "Chat"
        case "target": "Target chat"
        case "reaction": "Slack reactions"
        case "project": "Workbench" // tools.WorkbenchSurface keeps the pre-rename id
        case "automation": "Automations" // tools.AutomationSurface
        case "automation_editor": "Automation editor" // tools.AutomationEditorSurface
        case "tuning": "Tuning chat" // tools.SurfaceTuning
        default: surface
        }
    }
}
