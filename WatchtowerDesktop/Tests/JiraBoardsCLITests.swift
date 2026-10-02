import XCTest
@testable import WatchtowerDesktop

/// A per-site `jira … sync`/`boards` failure that wrote nothing to stderr
/// used to surface as a bare "sync failed" — the exit status, the only
/// diagnostic left, was dropped.
final class JiraBoardsCLITests: XCTestCase {
    func testEmptyStderrFailureKeepsTheExitStatus() async {
        let failure = await JiraBoardsCLI.run(cliPath: "/bin/sh", arguments: ["-c", "exit 3"], fallbackMessage: "sync failed")
        XCTAssertEqual(failure, "sync failed (exit 3)")
    }

    func testStderrFailureShowsTheStderr() async {
        let failure = await JiraBoardsCLI.run(
            cliPath: "/bin/sh", arguments: ["-c", "echo 'site gone' 1>&2; exit 1"], fallbackMessage: "sync failed"
        )
        XCTAssertEqual(failure, "site gone")
    }

    func testSuccessIsNil() async {
        let failure = await JiraBoardsCLI.run(cliPath: "/bin/sh", arguments: ["-c", "exit 0"], fallbackMessage: "sync failed")
        XCTAssertNil(failure)
    }
}
