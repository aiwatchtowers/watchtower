import XCTest
@testable import WatchtowerDesktop

/// A failing `db migrate` or `auth` CLI call says why: its stderr (or the
/// launch error) reaches the log or the error, never silence.
final class CLIMigrationsAndOAuthStderrTests: XCTestCase {
    private var scripts: [URL] = []

    override func tearDown() {
        scripts.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    /// A stub CLI: prints `stderr` to stderr and exits `code`.
    private func stubCLI(stderr: String, code: Int32) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-stub-\(UUID().uuidString)")
        try "#!/bin/sh\necho '\(stderr)' 1>&2\nexit \(code)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scripts.append(url)
        return url.path
    }

    func testMigrateFailureReportsItsStderr() throws {
        let cli = try stubCLI(stderr: "database is locked", code: 3)
        let reported = expectation(description: "failure reported")
        let line = Line()
        DatabaseManager.runCLIMigrations(cliPath: cli) {
            line.set($0)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 10)
        XCTAssertTrue(line.value.contains("exit code 3"), line.value)
        XCTAssertTrue(line.value.contains("database is locked"), line.value)
    }

    /// SB3 at the call site: more than the 64 KiB pipe buffer of stderr must
    /// not block the migrate until the 30 s watchdog kills it.
    func testMigrateLargeStderrIsDrainedNotTimedOut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-stub-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%300000s' '' 1>&2\necho 'database is locked' 1>&2\nexit 3\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scripts.append(url)
        let reported = expectation(description: "failure reported")
        let line = Line()
        DatabaseManager.runCLIMigrations(cliPath: url.path) {
            line.set($0)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 10)
        XCTAssertTrue(line.value.contains("exit code 3"), String(line.value.suffix(200)))
        XCTAssertFalse(line.value.contains("timed out"), String(line.value.suffix(200)))
    }

    func testMigrateLaunchFailureIsReported() {
        let reported = expectation(description: "launch failure reported")
        let line = Line()
        DatabaseManager.runCLIMigrations(cliPath: "/nonexistent/watchtower-\(UUID().uuidString)") {
            line.set($0)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 10)
        XCTAssertTrue(line.value.contains("could not start"), line.value)
    }

    func testMissingCLIIsReported() {
        let reported = expectation(description: "missing CLI reported")
        let line = Line()
        DatabaseManager.runCLIMigrations(cliPath: nil) {
            line.set($0)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 1)
        XCTAssertTrue(line.value.contains("not found"), line.value)
    }

    func testMigrateSuccessReportsNothing() throws {
        let cli = try stubCLI(stderr: "", code: 0)
        let reported = expectation(description: "nothing reported")
        reported.isInverted = true
        DatabaseManager.runCLIMigrations(cliPath: cli) { _ in reported.fulfill() }
        wait(for: [reported], timeout: 1)
    }

    func testOAuthCLIFailureCarriesTheStepAndStderr() async throws {
        let cli = try stubCLI(stderr: "keychain locked", code: 1)
        do {
            _ = try await SlackOAuthManager.obtainAuthURL(cliPath: cli)
            XCTFail("expected a failure")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("trust the local certificate"), text)
            XCTAssertTrue(text.contains("keychain locked"), text)
        }
    }
}

private final class Line: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    func set(_ value: String) { lock.withLock { stored = value } }
    var value: String { lock.withLock { stored } }
}
