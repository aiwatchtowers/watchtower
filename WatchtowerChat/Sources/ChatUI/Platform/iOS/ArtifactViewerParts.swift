#if os(iOS)
import SwiftUI

/// The phone's html artifact: the sandboxed web view (no network, no bridge, CHAT-05).
struct ChatArtifactHTMLView: View {
    let html: String

    var body: some View {
        SandboxedArtifactWebView(html: html)
    }
}

/// The phone has no extra viewer buttons (Print, Present and Open in Window are the Mac's).
struct ArtifactViewerExtras: View {
    let artifact: ChatArtifactContent

    var body: some View {
        EmptyView()
    }
}
#endif
