import Foundation

/// Human labels for the tool registry's chat surface ids (`Tool.Surfaces` in
/// `internal/tools/`), shown on Settings → Assistant tools.
package enum AssistantToolSurface {
    package static func label(for surface: String) -> String {
        switch surface {
        case "main": "Chat"
        case "target": "Target chat"
        case "reaction": "Slack reactions"
        case "project": "Workbench" // tools.WorkbenchSurface keeps the pre-rename id
        default: surface
        }
    }
}
