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

    /// Opens the popup with `prefill` in its composer (Search's Ask in chat); an existing draft is kept.
    func openHelpChat(prefill: String) {
        ensureChatViewModels()
        guard let chatViewModel else { return }
        chatViewModel.draft = HelpChatPrefill.merge(draft: chatViewModel.draft, prefill: prefill)
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

enum HelpChatPrefill {
    /// The composer shares the AI Chat draft: never overwrite what the owner typed.
    static func merge(draft: String, prefill: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == prefill { return prefill }
        return draft + "\n" + prefill
    }
}
