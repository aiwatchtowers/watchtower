#if os(macOS)
import SwiftUI

/// An html artifact on the Mac: the app's sandboxed web view (`SandboxedHTMLView`, CHAT-05 — no bridge, no network but
/// the CDN allowlist, navigation pinned to the page). Without one injected, the page's source as text: an html artifact
/// is never rendered outside the sandbox.
struct ChatArtifactHTMLView: View {
    let html: String
    @Environment(\.chatMacArtifactHooks) private var hooks

    var body: some View {
        if let htmlView = hooks.htmlView {
            htmlView(html)
        } else {
            ScrollView {
                Text(html).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}
#endif
