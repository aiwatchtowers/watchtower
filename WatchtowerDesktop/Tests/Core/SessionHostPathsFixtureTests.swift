import Foundation
import XCTest
@testable import WatchtowerCore

/// Go↔Swift dual path: the session host socket and workspace scope are
/// computed by both `internal/sessionhost/paths.go` and `SessionHostPaths`;
/// both read `internal/sessionhost/testdata/paths.json`.
final class SessionHostPathsFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Socket: Decodable {
            let bundleID: String
            let tempDir: String
            let want: String
            enum CodingKeys: String, CodingKey {
                case bundleID = "bundle_id"
                case tempDir = "temp_dir"
                case want
            }
        }
        struct Scope: Decodable {
            let dbPath: String
            let want: String
            enum CodingKeys: String, CodingKey {
                case dbPath = "db_path"
                case want
            }
        }
        let socket: [Socket]
        let scope: [Scope]
    }

    func testGoAndSwiftAgreeOnSocketAndScope() throws {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/sessionhost/testdata/paths.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.socket.isEmpty)
        XCTAssertFalse(fixture.scope.isEmpty)
        for c in fixture.socket {
            XCTAssertEqual(SessionHostPaths.socketPath(bundleID: c.bundleID, tempDir: c.tempDir), c.want, c.tempDir)
        }
        for c in fixture.scope {
            XCTAssertEqual(SessionHostPaths.scope(databasePath: c.dbPath), c.want, c.dbPath)
        }
    }
}
