import Foundation
import XCTest

/// The app never calls `conversations.mark` (Slack Developer Policy hygiene, #1769).
final class SlackServiceRemovedTests: XCTestCase {
    func testNoConversationsMark() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("conversations.mark"), "\(url.lastPathComponent) calls conversations.mark")
            XCTAssertFalse(text.contains("Mark read in Slack"), "\(url.lastPathComponent) has the Mark read button")
        }
        XCTAssertGreaterThan(scanned, 0)
    }
}
