import Foundation

/// The shared fixtures, read where they live (the Go readers stay unchanged).
enum ChatWireFixtures {
    /// The repository root, from …/WatchtowerChat/Tests/ChatWireTests/<this file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ChatWireTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerChat
        .deletingLastPathComponent()

    /// A file under `WatchtowerKit/Tests/Fixtures/`.
    static func kitFixture(_ path: String) -> URL {
        repoRoot.appendingPathComponent("WatchtowerKit/Tests/Fixtures/\(path)")
    }

    /// A file under `internal/` (the Go testdata).
    static func goFixture(_ path: String) -> URL {
        repoRoot.appendingPathComponent("internal/\(path)")
    }
}
