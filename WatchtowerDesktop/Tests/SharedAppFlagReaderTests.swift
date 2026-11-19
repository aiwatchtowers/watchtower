import XCTest
@testable import WatchtowerDesktop

/// `SharedAppFlagReader` (#1887 Task 25b): the ids Go flags on a retiring
/// shared app; a failed read keeps the last answer, none yet means no banner.
@MainActor
final class SharedAppFlagReaderTests: XCTestCase {
    func testReadsTheFlaggedIDs() async throws {
        let cli = try GoogleConnectionDetailTests.stubCLI(
            stdout: #"[{"id":1,"shared_gmail":true},{"id":2,"shared_gmail":false}]"#, test: self)
        let reader = SharedAppFlagReader.google()
        await reader.read(cliPath: cli.path)
        XCTAssertEqual(reader.accountIDs, [1])
        let args = try String(contentsOf: cli.log, encoding: .utf8)
        XCTAssertEqual(args.trimmingCharacters(in: .whitespacesAndNewlines), "google accounts --json")
    }

    func testFailureKeepsTheLastAnswer() async throws {
        let good = try GoogleConnectionDetailTests.stubCLI(stdout: #"[{"id":3,"shared_atlassian":true}]"#, test: self)
        let reader = SharedAppFlagReader.jira()
        await reader.read(cliPath: "/usr/bin/false")
        XCTAssertEqual(reader.accountIDs, [], "no banner on a first failed read")
        await reader.read(cliPath: nil)
        XCTAssertEqual(reader.accountIDs, [])
        await reader.read(cliPath: good.path)
        XCTAssertEqual(reader.accountIDs, [3])
        await reader.read(cliPath: "/usr/bin/false")
        XCTAssertEqual(reader.accountIDs, [3], "a failed run keeps the last flags")
        await reader.read(cliPath: "/usr/bin/true") // exit 0, no JSON
        XCTAssertEqual(reader.accountIDs, [3], "an unreadable answer keeps the last flags")
    }
}
