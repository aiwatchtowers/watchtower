import XCTest

/// CHAT-05 — artifacts never send. Every source on the artifact path may only
/// build URLs, copy to the pasteboard, open URLs and write local chat rows;
/// none may reach a process, the CLI, the network or the provider session.
///
/// `AssistantMessageBody` (the artifact-card renderer) lives in
/// `ChatMessageRow.swift` — it extends Task 14's existing type rather than a
/// separate file (preflight A36), so that file is scanned here too.
final class ArtifactChat05ScanTests: XCTestCase {
    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    func testChat05ArtifactSurfacesNeverWrite() throws {
        let files = [
            "WatchtowerCore/Services/Chat/ArtifactParser.swift",
            "WatchtowerCore/Services/Chat/ArtifactActions.swift",
            "WatchtowerCore/Services/Chat/ArtifactPanelModel.swift",
            "Views/Chat/ArtifactPanelView.swift",
            "Views/Chat/ArtifactCardView.swift",
            "Views/Chat/ArtifactActionPerformer.swift",
            "Views/Chat/ChatMessageRow.swift",
            "Views/Chat/ChatInspectorContent.swift",
            // Artifact comments (projects POC phase 6): comments reach the
            // assistant only as the owner's own message, sent by the chat.
            "WatchtowerCore/Services/Chat/ArtifactCommentsModel.swift",
            "WatchtowerCore/Services/Chat/ArtifactCommentMessage.swift",
            "WatchtowerCore/Services/Chat/ArtifactCommentReanchor.swift",
            "WatchtowerCore/Services/Chat/ArtifactCommentText.swift",
            "WatchtowerCore/Services/Chat/CommentBatchComposer.swift",
            "WatchtowerCore/Database/Queries/ArtifactCommentQueries.swift",
            "Views/Chat/ArtifactCommentsView.swift",
            // The selection-comment affordance the artifact panel shares with
            // project documents (#84).
            "Views/Comments/CommentableDocumentText.swift",
            "Views/Comments/DocumentTextView.swift",
            // Split out of / added beside them by #178–#181.
            "Views/Comments/DocumentAttributedString.swift",
            "Views/Comments/CommentTextEditor.swift",
            // The sandboxed web view an html artifact renders in (#535): its
            // controls are view-only, and it never reaches the loopback
            // server (workbench files only) or any socket.
            "Views/Common/SandboxedHTMLView.swift",
            "WatchtowerCore/Services/LocalPreview/HTMLPreviewPolicy.swift",
            // The in-app preview's file scheme handler (#563): read-only
            // from disk, no socket or URL loading of its own.
            "Views/Common/SandboxedHTMLSchemeHandler.swift"
        ]
        try assertNeverWrites(files)
    }

    /// CHAT-05 on the "Published on claude.ai" card (#737): the card and its
    /// model only open the claude.ai link or copy it — the same forbidden
    /// list as the artifact side. Publishing itself happens in the session,
    /// behind the gate; the card never sends.
    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    func testChat05PublishedLinkCardOnlyOpensOrCopies() throws {
        try assertNeverWrites([
            "WatchtowerCore/Services/Chat/PublishedLink.swift",
            "Views/Chat/PublishedLinkCardView.swift"
        ])
    }

    private static let forbidden = [
        "Process(", "CLIRunner", "URLSession", "findCLIPath", "WatchtowerAIService", "ChatSessionPool",
        ".send(", "sendDraft", "startTurn",
        // Nothing on the artifact side hands content to the
        // loopback server or opens a socket (#535).
        "LocalPreviewServer", "HTMLBrowserOpener", "NWConnection", "NWListener"
    ]

    private func assertNeverWrites(_ files: [String]) throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for token in Self.forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token) (CHAT-05)")
            }
        }
    }

    /// CHAT-05 on the loopback server's own path (#535): it answers local
    /// requests on connections it accepted and never opens one — no
    /// outbound connection, no URL loading, no process.
    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    func testChat05LoopbackServerNeverConnectsOut() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources/WatchtowerCore/Services/LocalPreview/LocalPreviewServer.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for token in ["URLSession", "NWConnection(to:", "NWConnection(host:", "NWConnection(", "Process(", "CLIRunner"] {
            XCTAssertFalse(text.contains(token), "LocalPreviewServer.swift must not reference \(token) (CHAT-05)")
        }
    }
}
