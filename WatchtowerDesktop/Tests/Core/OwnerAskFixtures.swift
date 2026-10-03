import Foundation

/// Go's `internal/asks/testdata` — the shared dual-path fixtures (see its
/// README.md), read in place.
enum OwnerAskFixtures {
    static func directory(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/asks/testdata/\(name)")
    }

    /// Every `*.json` of the directory, by file name.
    static func files(_ name: String) throws -> [(name: String, data: Data)] {
        let dir = directory(name)
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) }
    }

    /// A fixture field re-encoded as its own JSON text.
    static func json(_ value: Any) throws -> String {
        String(bytes: try JSONSerialization.data(withJSONObject: value), encoding: .utf8) ?? ""
    }
}
