import XCTest
@testable import WatchtowerDesktop

final class TrackScanServiceTests: XCTestCase {

    func testScanInvokesTracksScan() async throws {
        let runner = FakeCLIRunner(stdout: Data("[]".utf8))
        let events = try await TrackScanService(runner: runner).run(trackID: 7)
        XCTAssertEqual(runner.invocations.first, ["tracks", "scan", "7"])
        XCTAssertTrue(events.isEmpty)
    }

    func testEmptyOutputReturnsEmpty() async throws {
        let svc = TrackScanService(runner: FakeCLIRunner())
        let events = try await svc.run(trackID: 1)
        XCTAssertTrue(events.isEmpty)
    }

    func testEmptyJSONArrayDecodesToEmpty() async throws {
        let svc = TrackScanService(runner: FakeCLIRunner(stdout: Data("[]".utf8)))
        let events = try await svc.run(trackID: 1)
        XCTAssertTrue(events.isEmpty)
    }

    /// Malformed CLI output must throw (callers route it to errorMessage) —
    /// swallowing it would render a scan failure as "no new events".
    func testMalformedOutputThrows() async {
        let svc = TrackScanService(runner: FakeCLIRunner(stdout: Data("watchtower: boom".utf8)))
        do {
            _ = try await svc.run(trackID: 1)
            XCTFail("expected a decode error for malformed output")
        } catch {
            // expected
        }
    }

    func testPassesSinceFlag() async throws {
        let runner = FakeCLIRunner(stdout: Data("[]".utf8))
        let svc = TrackScanService(runner: runner)
        _ = try await svc.run(trackID: 7, since: "2026-01-01T00:00:00Z")
        XCTAssertEqual(runner.invocations.first,
                       ["tracks", "scan", "7", "--since", "2026-01-01T00:00:00Z"])
    }
}
