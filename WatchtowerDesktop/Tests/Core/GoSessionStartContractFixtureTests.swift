import Foundation
import XCTest
@testable import WatchtowerCore

/// Go↔Swift dual path (Go hub 3 Task 8): the placement lock path and the
/// reasons the Desktop tells apart are `internal/sessionstart/contract.go`'s
/// and `GoSessionStartContract`'s; both read
/// `internal/sessionstart/testdata/desktop_contract.json`.
final class GoSessionStartContractFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Lock: Decodable {
            let dbPath: String
            let workbench: Int64
            let want: String
            enum CodingKeys: String, CodingKey {
                case dbPath = "db_path"
                case workbench, want
            }
        }
        struct AgentNotFound: Decodable {
            let agent: String
            let want: String
        }
        struct Exit: Decodable {
            let code: Int32
            let error: String
        }
        let lock: [Lock]
        let agentNotFound: [AgentNotFound]
        let moveFailedPrefix: String
        let setupNotRunPrefix: String
        let agentNotFoundExit: Exit
        enum CodingKeys: String, CodingKey {
            case lock
            case agentNotFound = "agent_not_found"
            case moveFailedPrefix = "move_failed_prefix"
            case setupNotRunPrefix = "setup_not_run_prefix"
            case agentNotFoundExit = "agent_not_found_exit"
        }
    }

    func testGoAndSwiftAgreeOnTheStartContract() throws {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/sessionstart/testdata/desktop_contract.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.lock.isEmpty)
        for c in fixture.lock {
            XCTAssertEqual(GoSessionStartContract.lockPath(databasePath: c.dbPath, workbenchID: c.workbench), c.want)
        }
        XCTAssertFalse(fixture.agentNotFound.isEmpty)
        for c in fixture.agentNotFound {
            XCTAssertEqual(GoSessionStartContract.agentNotFoundReason(c.agent), c.want)
        }
        XCTAssertEqual(GoSessionStartContract.moveFailedPrefix, fixture.moveFailedPrefix)
        XCTAssertEqual(GoSessionStartContract.setupNotRunPrefix, fixture.setupNotRunPrefix)
        XCTAssertEqual(GoSessionStartContract.agentNotFoundExit, fixture.agentNotFoundExit.code)
    }

    /// The lock is exclusive: a second holder waits, then gets it once the
    /// first lets go.
    func testThePlacementLockIsExclusive() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-\(UUID().uuidString).place.lock").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let taken = await PlacementLock.acquire(path: path, waitingUpTo: .zero)
        let first = try XCTUnwrap(taken)
        let blocked = await PlacementLock.acquire(path: path, waitingUpTo: .milliseconds(60), step: .milliseconds(10))
        XCTAssertNil(blocked, "held by the first")
        first.release()
        let second = await PlacementLock.acquire(path: path, waitingUpTo: .zero)
        XCTAssertNotNil(second)
        second?.release()
    }

    /// A cancelled wait gives up at once with nil, the holder untouched.
    func testACancelledWaitReturnsNil() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-\(UUID().uuidString).place.lock").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let taken = await PlacementLock.acquire(path: path, waitingUpTo: .zero)
        let holder = try XCTUnwrap(taken)
        defer { holder.release() }
        let waiter = Task { await PlacementLock.acquire(path: path, waitingUpTo: .seconds(60)) }
        waiter.cancel()
        let started = ContinuousClock.now
        let got = await waiter.value
        XCTAssertNil(got)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "no wait to the deadline")
    }
}
