import XCTest
@testable import WatchtowerKit

final class OwnerAskDecodingTests: XCTestCase {
    private func reviewObject() throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/workbench/owner_ask_review.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testDecodesWithAndWithoutSpecReview() throws {
        var object = try reviewObject()
        object["spec_review"] = nil
        let without = try OwnerAsk.decode(payload: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(without.specReview)

        object["spec_review"] = ["status": "failed", "line": "Reviewer failed: timed out"]
        let with = try OwnerAsk.decode(payload: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(with.specReview, OwnerAsk.SpecReviewLine(status: "failed", line: "Reviewer failed: timed out"))
    }
}
