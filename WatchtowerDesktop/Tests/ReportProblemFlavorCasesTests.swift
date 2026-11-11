import XCTest
@testable import WatchtowerDesktop

/// The corp rule's Swift half (#1527): `AppState.isCorpBuild(_:)` decides the
/// sheet even when the CLI failed, Go's `diagnostics.Flavor` prints it. Both
/// read the one case table `internal/diagnostics/testdata/report_problem_flavor_cases.json`
/// (Go `TestFlavorCases`), the `policy_cases.json` pattern.
final class ReportProblemFlavorCasesTests: XCTestCase {
    private struct FlavorCase: Decodable {
        let buildFlavor: String
        let flavor: String

        enum CodingKeys: String, CodingKey {
            case buildFlavor = "build_flavor"
            case flavor
        }
    }

    func testSharedFlavorCases() throws {
        let table = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/diagnostics/testdata/report_problem_flavor_cases.json")
        let cases = try JSONDecoder().decode([FlavorCase].self, from: Data(contentsOf: table))
        XCTAssertFalse(cases.isEmpty, "the shared table lists no case")
        for item in cases {
            XCTAssertTrue(["default", "corp"].contains(item.flavor), "unknown flavor \(item.flavor)")
            XCTAssertEqual(
                AppState.isCorpBuild(item.buildFlavor), item.flavor == "corp",
                "build flavor \(item.buildFlavor.debugDescription)"
            )
        }
    }
}
