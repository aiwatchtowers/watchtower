import XCTest

/// Chat performance + "comments go as one batch" for quote-reply (projects
/// POC phase 6, selection quoting since #536): the thread's row, thread,
/// feed and markdown files host no text view themselves — since spec
/// 2026-10-24 §5b (ask #539) the one text view is a finished answer's run
/// of prose (`MarkdownTextRun.swift`), never the streaming reply's — and
/// neither the selection overlay nor the batch view can send: the batch
/// goes out only through the chat's own send.
final class ChatSelectionQuoteScanTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        return try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    func testThreadRowsNeverHostATextView() throws {
        for file in ["Views/Chat/ChatMessageRow.swift", "Views/Chat/ChatThreadView.swift", "Views/Chat/MarkdownView.swift",
                     "Views/Chat/ChatFeedView.swift"] {
            let text = try source(file)
            for token in ["NSTextView", "DocumentTextView", "NSViewRepresentable"] {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token): the run view is MarkdownTextRun's")
            }
        }
        // Only a finished answer draws native text; the streaming one stays SwiftUI.
        XCTAssertTrue(try source("Views/Chat/ChatMessageRow.swift").contains("MarkdownView(text: markdown, nativeText: !isRunning)"))
    }

    func testTheSelectionOverlayAndTheBatchViewNeverSend() throws {
        for file in ["Views/Chat/ChatSelectionQuote.swift", "Views/Chat/QuoteBatchView.swift"] {
            let text = try source(file)
            for token in [".send(", "sendDraft", "startTurn", "ChatSessionPool", "Process(", "URLSession"] {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token)")
            }
        }
    }
}
