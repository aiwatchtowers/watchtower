import AppKit
import ChatUI
import DesignKit
import SwiftUI

/// The Mac's controls for the shared chat views (unified chat spec §14, D18): ChatUI draws its buttons, cards and
/// chips through this style, so the chat looks like the rest of the app (DesignKit's kit styles and card).
struct DesignKitChatStyle: ChatUIStyle {
    func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(.kitPrimary))
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(.kitQuiet))
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView {
        AnyView(content().padding(Spacing.cozy).frame(maxWidth: .infinity, alignment: .leading).card())
    }

    func chip(_ title: String) -> AnyView {
        AnyView(Chip(text: title, color: .secondary))
    }

    /// The Mac's multi-line comment editor: Return is a new line, ⌘↩ sends a complete card.
    func questionOtherField(text: Binding<String>, placeholder: String, onSubmit: (() -> Void)?) -> AnyView {
        AnyView(CommentTextEditor(text: text, placeholder: placeholder, onSubmit: onSubmit))
    }
}

extension View {
    /// The shared chat views with the Mac's controls and artifact presentation.
    func macChatStyle(hooks: ChatMacArtifactHooks) -> some View {
        environment(\.chatUIStyle, DesignKitChatStyle())
            .environment(\.chatMacArtifactHooks, hooks)
    }
}

extension ChatMacArtifactHooks {
    /// The app's artifact presentation (ruling F20): the sandboxed web view, the print panel, and the preview window
    /// (Present is full screen). Each only shows or prints a page (CHAT-05).
    @MainActor static var app: ChatMacArtifactHooks {
        ChatMacArtifactHooks(
            htmlView: { html in AnyView(SandboxedHTMLView(content: .page(html))) },
            print: { artifact in
                ArtifactPrinter.print(artifact.draft, window: NSApp.keyWindow ?? NSApp.mainWindow) { _ in }
            },
            present: { artifact in
                HTMLPreviewWindow.show(.page(artifact.content), title: artifact.title, fullScreen: true)
            },
            openInWindow: { artifact in
                HTMLPreviewWindow.show(.page(artifact.content), title: artifact.title, fullScreen: false)
            }
        )
    }
}
