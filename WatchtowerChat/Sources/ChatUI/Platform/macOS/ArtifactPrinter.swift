#if os(macOS)
import SwiftUI
import WatchtowerDesign

/// The Mac's extra viewer buttons: Print…, Present and Open in Window, each the app's hook (`ChatMacArtifactHooks`).
/// CHAT-05: printing and showing only — nothing here sends.
struct ArtifactViewerExtras: View {
    static let printLabel = "Print…"
    static let presentLabel = "Present"
    static let openInWindowLabel = "Open in Window"

    let artifact: ChatArtifactContent
    @Environment(\.chatMacArtifactHooks) private var hooks
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        HStack(spacing: Spacing.small) {
            if let print = hooks.print {
                style.secondaryButton(Self.printLabel) { print(artifact) }
            }
            if artifact.kind == "html", let present = hooks.present {
                style.secondaryButton(Self.presentLabel) { present(artifact) }
            }
            if let openInWindow = hooks.openInWindow {
                style.secondaryButton(Self.openInWindowLabel) { openInWindow(artifact) }
            }
        }
    }
}
#endif
