import AppKit
import WebKit

extension AppState {
    func toggleHelpChat() {
        if !isHelpChatShown { ensureChatViewModels() }
        isHelpChatShown.toggle()
    }

    /// Opens the popup with `prefill` typed into its composer (Search's Ask in chat).
    func openHelpChat(prefill: String) {
        ensureChatViewModels()
        chatViewModel?.draft = prefill
        isHelpChatShown = true
    }

    /// ⌘/ (Help → Ask Watchtower…).
    func askWatchtower() {
        let webView = Self.webViewWithKeyboard()
        switch HelpChatPolicy.action(destination: selectedDestination, editorHasKeyboard: webView != nil) {
        case .focusChatComposer:
            HelpChatFocus.focusComposer(in: NSApp.keyWindow)
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

enum HelpChatFocus {
    /// Puts the caret in the first editable text view under `window`'s content.
    @MainActor
    static func focusComposer(in window: NSWindow?) {
        guard let window, let field = firstEditableTextView(in: window.contentView) else { return }
        window.makeFirstResponder(field)
    }

    private static func firstEditableTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        for sub in view.subviews {
            if let found = firstEditableTextView(in: sub) { return found }
        }
        return nil
    }
}
