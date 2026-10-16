import WatchtowerKit
import WatchtowerSync
import XCTest

/// The optional `column` of the `workbench_target` slice (board #267): the
/// column title when the workbench defines columns. Old hubs omit it.
final class WorkbenchTargetTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/workbench/workbench_target.json")

    private func payload(column: String?) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        if let column { json["column"] = column }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testDecodesWithAndWithoutColumn() throws {
        XCTAssertNil(try WorkbenchTarget.decode(payload: payload(column: nil)).column)
        XCTAssertEqual(try WorkbenchTarget.decode(payload: payload(column: "QA")).column, "QA")
    }
}
