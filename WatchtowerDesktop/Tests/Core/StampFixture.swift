import Foundation

/// `internal/db/testdata/stamps/stamps.json`: the stamps Go writes into the
/// `agent_state_at`-layout columns, shared by the Go and Swift tests (spec
/// 2026-10-10-owner-asks-v2 Part 2.5, E35). Read only, never rewritten.
struct StampFixture: Decodable {
    struct Valid: Decodable {
        let stamp: String
        let unixMS: Int64

        enum CodingKeys: String, CodingKey {
            case stamp
            case unixMS = "unix_ms"
        }
    }

    let layout: String
    let columns: [String]
    let valid: [Valid]
    let invalid: [String]

    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/stamps/stamps.json")
    }

    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
