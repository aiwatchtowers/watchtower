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
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
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
            "Views/Chat/ArtifactCommentsView.swift"
        ]
        let forbidden = ["Process(", "CLIRunner", "URLSession", "findCLIPath", "WatchtowerAIService", "ChatSessionPool",
                         ".send(", "sendDraft", "startTurn"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token) (CHAT-05)")
            }
        }
    }
}
