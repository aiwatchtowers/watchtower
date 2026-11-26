import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Pasted images in the Workchat feed: the echoed owner lines and the outgoing bubble read `[Image #N]`, as the
/// field did, instead of the saved files' paths. No file is on disk: the bubble never looks at one.
@MainActor
enum WorkchatPastedImageShotFixtures {
    static let shots: [DesignShot] = [
        DesignShot(name: "workchat-pasted-image", size: NSSize(width: 720, height: 480)) { view() }
    ]

    private static func view() -> AnyView {
        let pastes = "/Users/example/.local/share/watchtower/acme/workchat-attachments/7"
        let now = Date()
        let entries = [
            SessionFeedEntry(id: "o1", kind: "owner", at: now - 600,
                             text: "and the mockup\n/Users/example/Desktop/mockup.png"),
            SessionFeedEntry(id: "o2", kind: "owner", at: now - 300,
                             text: "\(pastes)/20261125-101500-1.png the transcriber does not work, compare with "
                                 + "\(pastes)/20261125-101500-2.png\n[image]"),
            SessionFeedEntry(id: "a2", kind: "agent", at: now - 280,
                             text: "I see the error banner in the first screenshot. Checking the recorder logs.")
        ]
        var feed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) { _ in }
        feed.highlighting = .workchatShot
        var context = feed.context()
        let sending = "\(pastes)/20261125-102000-1.png"
        let line = WorkchatOutgoing(id: UUID(), text: "\(sending) and this one after the fix", sentAt: now,
                                    state: .sending, typedText: "[Image #1] and this one after the fix",
                                    attachmentPaths: [sending])
        context.footer = AnyView(WorkchatOutgoingBubble(line: line, onCancel: {}, onShowTerminal: {}))
        return AnyView(
            ChatUI.ChatFeedView(messages: feed.messages, context: context)
                .macChatStyle(hooks: .app, look: .workchat)
                .detailBackground()
        )
    }
}
