import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Board #1008: the Mac's session row words the merged share from the same
/// case file the Kit's `TerminalSessionState.reportMergedText` test reads
/// (`WatchtowerKit/Tests/Fixtures/workbench/merged_share_cases.json`), so the
/// phone and the Mac cannot drift apart.
final class MergedShareParityTests: XCTestCase {
    func testTheRowCaptionWordsTheSharedCases() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MobileHub
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
            .appendingPathComponent("WatchtowerKit/Tests/Fixtures/workbench/merged_share_cases.json")
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(file["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let total = item["total"] as? Int ?? 0
            let summary = SessionReportSummary(
                sessionID: 1, done: 0, total: total,
                merged: item["merged"] as? Int ?? 0, mergedStale: item["stale"] as? Bool ?? false
            )
            let expected = [total > 0 ? "0/\(total)" : nil, item["text"] as? String].compactMap { $0 }.joined(separator: " · ")
            XCTAssertEqual(SessionReportPresentation.rowCaption(summary), expected, "\(item)")
        }
    }
}
