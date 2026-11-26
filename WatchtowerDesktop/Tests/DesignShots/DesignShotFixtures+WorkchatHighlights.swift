import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerChatText
import WatchtowerCore
@testable import WatchtowerDesktop

/// The agent's text with IDE-style highlights (spec 2026-11-24-workchat-polish §2, #2201 T2) on the built feed:
/// `workchat-polish-real-04-agent-text-highlights` beside the mockup's `workchat-polish-04-agent-text-highlights`, the
/// same four paragraphs drawn by ChatUI's feed with `WorkchatFeed.context()`. The paths resolve for real
/// (`WorkchatHighlights`' live lookup) in a scratch folder: the bare `CloudKitTransport+LinkDirect.swift` through the
/// root's code index (a `WorkbenchCodeIndex` fed the folder's files, as `CodeIndexCenter` feeds it) on a unique
/// base-name hit, `internal/sessionhost/prompt_state.go` on disk.
@MainActor
enum WorkchatHighlightShotFixtures {
    static let shots: [DesignShot] = [
        DesignShot(name: "workchat-polish-real-04-agent-text-highlights", prepare: {
            try await prepared()
        }, size: NSSize(width: 720, height: 480))
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

    static let folderFiles = [
        "WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport+LinkDirect.swift",
        "internal/sessionhost/prompt_state.go"
    ]

    /// The scratch folder with the two files, the lookups landed, then the feed.
    private static func prepared() async throws -> AnyView {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workchat-highlights-shot")
        for file in folderFiles {
            let url = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let root = CodeRoot(workbenchID: 1, worktree: folder)
        let index = WorkbenchCodeIndex()
        index.applyIndexLines(folderFiles.map { .file(CodeIndexFileResult(file: $0, lang: "", symbols: [])) },
                              from: .fullRun)
        let highlights = WorkchatHighlights()
        let messageID = WorkchatFeedAdapter.messageID("a")
        for span in AgentTextHighlights.spans(inPlain: agentText) where span.kind == .path {
            _ = highlights.resolves(span.text, messageID: messageID, root: root, epoch: 1,
                                    revision: index.filesRevision, indexFiles: index.files)
        }
        await highlights.lookupsFinished()
        return AnyView(feed(highlights, root: root, index: index))
    }

    private static func feed(_ highlights: WorkchatHighlights, root: CodeRoot, index: WorkbenchCodeIndex) -> some View {
        let entries = [SessionFeedEntry(id: "a", kind: "agent", text: agentText)]
        var workchatFeed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) { _ in }
        workchatFeed.highlighting = AgentTextHighlighting(
            resolvesPath: { path, messageID in
                highlights.resolves(path, messageID: messageID, root: root, epoch: 1, revision: index.filesRevision,
                                    indexFiles: index.files)
            },
            openHighlight: { _, _ in })
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
