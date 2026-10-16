import AppKit
import WebKit

extension AppState {
    func toggleHelpChat() {
        if isHelpChatShown {
            isHelpChatShown = false
            return
        }
        ensureChatViewModels()
        isHelpChatShown = chatViewModel != nil
    }

    /// Opens the popup with `prefill` typed into its composer (Search's Ask in chat).
    func openHelpChat(prefill: String) {
        ensureChatViewModels()
        guard let chatViewModel else { return }
        chatViewModel.draft = prefill
        isHelpChatShown = true
    }

    /// ⌘/ (Help → Ask Watchtower…).
    func askWatchtower() {
        let webView = Self.webViewWithKeyboard()
        switch HelpChatPolicy.action(destination: selectedDestination, editorHasKeyboard: webView != nil) {
        case .focusChatComposer:
            chatComposerFocusTick += 1
        case .editorToggleComment:
            // A web view without a focused Monaco text (a diff, a recipe form)
            // answers false: the popup opens instead.
            Task {
                let script = "(window.wt && wt.toggleComment) ? wt.toggleComment() : false"
                let handled = try? await webView?.evaluateJavaScript(script) as? Bool
                if handled != true { toggleHelpChat() }
            }
        case .togglePopup:
            toggleHelpChat()
        }
    }

    /// The web view that is, or contains, the key window's first responder.
    private static func webViewWithKeyboard() -> WKWebView? {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if let web = current as? WKWebView { return web }
            view = current.superview
        }
        return nil
    }
}
