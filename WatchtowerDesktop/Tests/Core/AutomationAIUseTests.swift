import Foundation
import XCTest
@testable import WatchtowerCore

/// The Swift twin decides "this manifest grants AI" exactly as Go's
/// `automations.PermissionsUseAI`, over the one shared fixture (#1886,
/// Decision 5).
final class AutomationAIUseTests: XCTestCase {
    private static func fixture() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/testdata/uses_ai_cases.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(obj as? [[String: Any]])
    }

    func testSharedFixture() throws {
        let cases = try Self.fixture()
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let permissions = try XCTUnwrap(c["permissions"] as? [String])
            let want = try XCTUnwrap(c["uses_ai"] as? Bool)
            XCTAssertEqual(AutomationAIUse.usesAI(permissions: permissions), want, "\(permissions)")
        }
    }

    /// Go trims each entry and reads the capability and verb ignoring case.
    func testEntriesAreNormalised() {
        XCTAssertTrue(AutomationAIUse.usesAI(permissions: ["  LLM:Light "]))
        XCTAssertTrue(AutomationAIUse.usesAI(permissions: ["Agent:RUN@x"]))
        XCTAssertFalse(AutomationAIUse.usesAI(permissions: ["agent:list"]))
        XCTAssertFalse(AutomationAIUse.usesAI(permissions: ["builtin:unknown.primitive"]))
    }
}
