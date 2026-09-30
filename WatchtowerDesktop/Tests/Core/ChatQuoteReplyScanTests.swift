import XCTest

/// Chat performance + "comments go as one batch" for quote-reply (projects
/// POC phase 6): no thread row hosts a text view (only the quote sheet does,
/// while it is open), and neither the sheet nor the batch view can send — the
/// batch goes out only through the chat's own send.
final class ChatQuoteReplyScanTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        return try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    func testThreadRowsNeverHostATextView() throws {
        for file in ["Views/Chat/ChatMessageRow.swift", "Views/Chat/ChatThreadView.swift", "Views/Chat/MarkdownView.swift"] {
            let text = try source(file)
            for token in ["NSTextView", "DocumentTextView", "NSViewRepresentable"] {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token): rows stay SwiftUI text")
            }
        }
    }

    func testTheQuoteSheetAndTheBatchViewNeverSend() throws {
        for file in ["Views/Chat/QuoteReplySheet.swift", "Views/Chat/QuoteBatchView.swift"] {
            let text = try source(file)
            for token in [".send(", "sendDraft", "startTurn", "ChatSessionPool", "Process(", "URLSession"] {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token)")
            }
        }
    }
}
