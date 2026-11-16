#if os(macOS)
import SwiftUI

/// The Mac's artifact presentation the app hosts (ruling F20: `SandboxedHTMLView`, `ArtifactPrinter` and the Present
/// / Open in Window windows are AppKit-bound and shared with the workbench's previews, so they stay in the app and
/// reach ChatUI's macOS part through this injection). Every hook only shows a page, prints it or opens a window over
/// it (CHAT-05); nil hides the button.
public struct ChatMacArtifactHooks {
    /// The sandboxed web view of an html artifact.
    public var htmlView: ((String) -> AnyView)?
    public var print: ((ChatArtifactContent) -> Void)?
    public var present: ((ChatArtifactContent) -> Void)?
    public var openInWindow: ((ChatArtifactContent) -> Void)?

    public init(
        htmlView: ((String) -> AnyView)? = nil,
        print: ((ChatArtifactContent) -> Void)? = nil,
        present: ((ChatArtifactContent) -> Void)? = nil,
        openInWindow: ((ChatArtifactContent) -> Void)? = nil
    ) {
        self.htmlView = htmlView
        self.print = print
        self.present = present
        self.openInWindow = openInWindow
    }
}

private struct ChatMacArtifactHooksKey: EnvironmentKey {
    static let defaultValue = ChatMacArtifactHooks()
}

extension EnvironmentValues {
    /// The app's artifact presentation for the shared viewer (the Mac only).
    public var chatMacArtifactHooks: ChatMacArtifactHooks {
        get { self[ChatMacArtifactHooksKey.self] }
        set { self[ChatMacArtifactHooksKey.self] = newValue }
    }
}
#endif
