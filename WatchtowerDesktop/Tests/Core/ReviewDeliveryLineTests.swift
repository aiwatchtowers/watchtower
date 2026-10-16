import XCTest
@testable import WatchtowerCore

/// The line typed into a session after Send: the same text as Go's
/// `reviewdiff.DeliveryLine` for every `internal/reviewdiff/testdata/lines` fixture.
final class ReviewDeliveryLineTests: XCTestCase {
    func testMatchesGoFixtures() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/reviewdiff/testdata/lines")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        struct Fixture: Decodable { let round_id: Int64; let comments: Int; let line: String }
        for url in files {
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            XCTAssertEqual(ReviewDeliveryLine.line(roundID: fx.round_id, comments: fx.comments), fx.line, url.lastPathComponent)
        }
    }
}
