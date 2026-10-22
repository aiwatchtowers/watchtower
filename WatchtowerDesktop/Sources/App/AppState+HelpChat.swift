import AppKit
import WatchtowerCore
import WebKit

extension AppState {
    func toggleHelpChat() {
        if isHelpChatShown {
            isHelpChatShown = false
            return
        }
        ensureChatViewModels()
        resumeLastChatIfUnopened()
        guard chatViewModel != nil else { return }
        // From the Settings window or tray-only mode the popup's window
        // comes forward first.
        bringMainWindowForward()
        isHelpChatShown = true
    }

    /// After a relaunch the AI Chat tab has not made its resume decision yet:
    /// the popup runs the same `enterTab` landing policy from the keys the tab
    /// stores, so it continues the last chat too.
    private func resumeLastChatIfUnopened() {
        guard let chatViewModel, chatViewModel.conversationID == nil else { return }
        let defaults = UserDefaults.standard
        let workspace = databaseManager?.dbPool.path ?? ""
        let sameWorkspace = defaults.string(forKey: "chat.lastWorkspace") == workspace
        let lastID = defaults.integer(forKey: "chat.lastConversationID")
        let viewedAt = defaults.double(forKey: "chat.lastViewedAt")
        chatViewModel.enterTab(
            rememberedConversationID: sameWorkspace && lastID != 0 ? Int64(lastID) : nil,
            lastViewedAt: sameWorkspace && viewedAt != 0 ? Date(timeIntervalSince1970: viewedAt) : nil,
            now: Date())
    }

    /// Opens the popup with `prefill` in its composer (Search's Ask in chat); an existing draft is kept.
    func openHelpChat(prefill: String) {
        ensureChatViewModels()
        guard let chatViewModel else { return }
        resumeLastChatIfUnopened()
        chatViewModel.draft = HelpChatPrefill.merge(draft: chatViewModel.draft, prefill: prefill)
        isHelpChatShown = true
    }

    /// ⌘/ (Help → Ask Watchtower…).
    func askWatchtower() {
        let webView = Self.webViewWithKeyboard()
        switch HelpChatPolicy.action(destination: selectedDestination, editorHasKeyboard: webView != nil) {
        case .focusChatComposer:
            bringMainWindowForward()
            chatViewModel?.requestComposerFocus()
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

    /// The sidebar destinations shown right now (feature and source rules):
    /// the only screens a `watchtower-nav://` link in a chat answer may open.
    /// While the Inbox shows, the old Briefings, Day Plan, Tracks and Ideas
    /// names count too (`InboxRoute.aliasHosts`): they open its filters.
    var visibleHelpScreenIDs: Set<String> {
        let disabled = featureVisibility.disabledFeatureIDs
        let connected = featureVisibility.connectedSources
        let visible = SidebarDestination.allCases.filter { $0.isVisible(disabledFeatures: disabled, connected: connected) }
        var ids = Set(visible.map(\.rawValue))
        if visible.contains(.inbox) { ids.formUnion(InboxRoute.aliasHosts.keys) }
        return ids
    }

    /// A `watchtower-nav://<screen>` link from AI Chat, the popup or an Inbox
    /// card: opens a visible screen — an old screen name its Inbox filter —
    /// and closes the popup. An unknown or hidden screen is ignored (the link
    /// does nothing).
    func openNavLink(_ url: URL) {
        guard let raw = NavLink.destination(from: url, allowed: visibleHelpScreenIDs) else { return }
        if let route = InboxRoute.fromNavHost(raw, today: Self.inboxToday()) {
            openInbox(route)
        } else if let destination = SidebarDestination(rawValue: raw) {
            selectedDestination = destination
        } else {
            return
        }
        isHelpChatShown = false
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
