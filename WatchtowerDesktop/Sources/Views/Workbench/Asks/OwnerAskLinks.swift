import AppKit
import SwiftUI
import WatchtowerCore

/// Links in an ask's text (#394): a workbench path (`path:line`, or a
/// link to a path) opens the file in Files — a beep when it is not a file
/// of the folder — and any scheme of the app-wide allowlist (http(s),
/// mailto, slack…) goes to the system. A link of any other scheme is
/// never clickable: `MarkdownView` strips it before it renders. A
/// modifier of its own: it is rebuilt only when the workbench changes,
/// not on every keystroke into the draft (an `OpenURLAction` cannot be
/// compared — `MarkdownView`).
struct OwnerAskLinks: ViewModifier {
    let vm: WorkbenchesViewModel
    let projectID: Int64

    enum Route: Equatable {
        case file(OpenQuicklyTarget)
        case system
        /// A workbench link naming no file of the folder (`../x.go:3`),
        /// or a scheme past the allowlist.
        case refused
    }

    static func askLinkRoute(_ url: URL) -> Route {
        if let target = CodeLineLinks.target(from: url) { return .file(target) }
        return AllowedURLSchemes.permits(url) ? .system : .refused
    }

    /// What a click on `url` does: a file opens through `openFile`, an
    /// allowlisted scheme goes to the system, anything else beeps.
    static func handleAskLink(_ url: URL, openFile: (OpenQuicklyTarget) -> Void, beep: () -> Void) -> OpenURLAction.Result {
        switch askLinkRoute(url) {
        case let .file(target):
            openFile(target)
            return .handled
        case .system:
            return .systemAction
        case .refused:
            beep()
            return .handled
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.markdownCodeLinks, true)
            .environment(\.openURL, OpenURLAction { [vm, projectID] url in
                Self.handleAskLink(url, openFile: { target in
                    // A beep when it names no file of the folder.
                    Task {
                        if !(await vm.openAskLink(target, projectID: projectID)) { NSSound.beep() }
                    }
                }, beep: NSSound.beep)
            })
    }
}
