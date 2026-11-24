import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// The agent's text with IDE-style highlights (spec 2026-11-24-workchat-polish §2, #2201 T2) on the built feed:
/// `workchat-polish-real-04-agent-text-highlights` beside the mockup's `workchat-polish-04-agent-text-highlights`, the
/// same four paragraphs drawn by ChatUI's feed with `WorkchatFeed.context()` (the two paths resolve).
@MainActor
enum WorkchatHighlightShotFixtures {
    static let shots: [DesignShot] = [
        DesignShot(name: "workchat-polish-real-04-agent-text-highlights", size: NSSize(width: 720, height: 480)) {
            AnyView(feed)
        }
    ]

    static let agentText = """
    Round 3 of #2188 is ready (67a59755a). The last diff is small, so I am reading it myself and Codex runs in \
    parallel.

    For #2188 the whole gate runs: `make test`, `make test-swift`, `make lint-all`, the leak check and the guide \
    check. About 30–40 minutes.

    #2189 is still with the implementer. The SourceKit error in CloudKitTransport+LinkDirect.swift is indexer noise \
    again, not a build error.

    Codex found no blockers. One gap: no test covers the hidden-window → `.gone` transition; see \
    internal/sessionhost/prompt_state.go.
    """

    private static var feed: some View {
        let entries = [SessionFeedEntry(id: "a", kind: "agent", text: agentText)]
        var workchatFeed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) { _ in }
        workchatFeed.resolvesPath = { _ in true }
        workchatFeed.onHighlight = { _ in }
        var context = workchatFeed.context()
        var follow = ChatFeedFollow(conversationID: 1)
        follow.anchorsBottom = true
        context.follow = follow
        return ChatUI.ChatFeedView(messages: workchatFeed.messages, context: context)
            .macChatStyle(hooks: .app, look: .workchat)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .detailBackground()
    }
}
