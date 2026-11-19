import XCTest
@testable import WatchtowerCore

/// Go↔Swift dual path: `chatengine.SocketPath`/`SessionSocketPath` and
/// `ChatSocketPaths` both read `internal/chatengine/testdata/socket_paths.json`.
final class ChatSocketPathsTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let workspace: String
            let tempDir: String
            let conversation: Int64
            let chatSocket: String
            let sessionSocket: String
            enum CodingKeys: String, CodingKey {
                case name, workspace, conversation
                case tempDir = "temp_dir"
                case chatSocket = "chat_socket"
                case sessionSocket = "session_socket"
            }
        }
        let max: Int
        let cases: [Case]
    }

    func testFixtureCases() throws {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/chatengine/testdata/socket_paths.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.max, ChatSocketPaths.maxSocketPath)
        XCTAssertFalse(fixture.cases.isEmpty)
        for c in fixture.cases {
            XCTAssertEqual(ChatSocketPaths.socketPath(workspace: c.workspace, tempDir: c.tempDir), c.chatSocket, c.name)
            XCTAssertEqual(ChatSocketPaths.sessionSocketPath(workspace: c.workspace, tempDir: c.tempDir,
                                                             conversation: c.conversation),
                           c.sessionSocket, c.name)
        }
    }
}
