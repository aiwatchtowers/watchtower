import AppKit
import ChatUI
import SwiftUI
import WatchtowerChatText

extension View {
    /// An artifact card of an embedded chat opens the shared viewer in a sheet.
    func embeddedArtifactSheet(_ artifact: Binding<ChatArtifactContent?>) -> some View {
        sheet(item: artifact) { content in
            VStack(spacing: 0) {
                ArtifactViewer(artifact: content, openURL: { url in
                    if AllowedURLSchemes.permits(url) { NSWorkspace.shared.open(url) }
                }, copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                })
                .environment(\.chatHostText, .mac)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { artifact.wrappedValue = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(Spacing.cozy)
            }
            .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        }
    }
}
