import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

final class MobileHubCLIReasonTests: XCTestCase {
    private func reason(_ stderr: String) -> String {
        MobileHubCLI.reason(CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
    }

    func testLowercaseSentenceIsCapitalised() {
        XCTAssertEqual(reason("Error: the code expired"), "The code expired.")
    }

    func testMixedCaseFirstWordKeepsItsSpelling() {
        XCTAssertEqual(
            reason("Error: iCloud could not be reached from this Mac: try again in a moment"),
            "iCloud could not be reached from this Mac: try again in a moment."
        )
    }
}
