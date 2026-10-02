import Foundation

/// The ⌘K palette's labels (board #252), kept out of the view so they are
/// testable.
package enum GoToPresentation {
    /// "SESSIONS · ALPHA" over the page's own sessions, "OTHER WORKBENCHES"
    /// over the rest.
    package static func sectionTitle(_ kind: GoToSection.Kind, currentWorkbench: String) -> String {
        switch kind {
        case .currentSessions: "SESSIONS · \(currentWorkbench.uppercased())"
        case .otherWorkbenches: "OTHER WORKBENCHES"
        }
    }

    /// A session row's title: its own under the current workbench's
    /// section, `<workbench> › <session>` under another's.
    package static func sessionTitle(_ session: TerminalSession, workbench: Workbench, currentWorkbenchID: Int64?) -> String {
        workbench.id == currentWorkbenchID ? session.title : "\(workbench.name) › \(session.title)"
    }
}
