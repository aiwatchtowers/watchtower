import XCTest
@testable import WatchtowerCore

/// The lines typed into a session after Send and Approve: the same text as
/// Go's `reviewdiff.DeliveryLine` / `ApprovedLine` for every
/// `internal/reviewdiff/testdata/lines` fixture (`kind: "approved"` pins the
/// approved line; no `kind` is the sent line).
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
        XCTAssertGreaterThanOrEqual(files.count, 4)
        struct Fixture: Decodable { let round_id: Int64; let comments: Int?; let kind: String?; let line: String }
        var approved = 0
        for url in files {
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            switch fx.kind {
            case nil:
                let comments = try XCTUnwrap(fx.comments, url.lastPathComponent)
                XCTAssertEqual(ReviewDeliveryLine.line(roundID: fx.round_id, comments: comments), fx.line, url.lastPathComponent)
            case "approved":
                approved += 1
                XCTAssertEqual(ReviewDeliveryLine.approved(roundID: fx.round_id), fx.line, url.lastPathComponent)
            case let other:
                XCTFail("\(url.lastPathComponent): unknown kind \(other ?? "")")
            }
        }
        XCTAssertEqual(approved, 1, "approved.json pins the approved line")
    }
}
