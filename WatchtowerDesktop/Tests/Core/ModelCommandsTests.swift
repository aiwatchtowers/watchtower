import XCTest
@testable import WatchtowerCore

/// The Desktop's copy of the shared model-command list and its matcher
/// (background AI consent, #1886 Task 18).
final class ModelCommandsTests: XCTestCase {
    /// `ModelCommands.paths` rendered in the Go fixture's layout is the
    /// fixture, byte for byte: the Desktop refuses exactly the commands the
    /// CLI declares as model-running.
    func testBundledListMatchesGoFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/aiconsent/testdata/model_commands.json")
        let goBytes = try Data(contentsOf: fixture)
        let rows = ModelCommands.paths.map { "  [" + $0.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
        let rendered = "[\n" + rows.joined(separator: ",\n") + "\n]\n"
        XCTAssertEqual(Data(rendered.utf8), goBytes,
                       "ModelCommands.paths drifted from internal/aiconsent/testdata/model_commands.json")
    }

    func testMatchSkipsGlobalFlags() {
        XCTAssertEqual(ModelCommands.match(["digest", "generate"]), "digest generate")
        XCTAssertEqual(ModelCommands.match(["--config", "/x", "digest", "generate"]), "digest generate")
        XCTAssertEqual(ModelCommands.match(["--db", "/x.db", "--config", "/x", "digest", "generate", "--json"]),
                       "digest generate")
        XCTAssertEqual(ModelCommands.match(["--config=/x", "-v", "coach", "run", "--json"]), "coach run")
        // Inner flags with a value, as cobra places them.
        XCTAssertEqual(ModelCommands.match(["jira", "--account", "3", "boards", "analyze", "--force", "7"]),
                       "jira boards analyze")
        XCTAssertEqual(ModelCommands.match(["ai", "--provider", "codex", "test"]), "ai test")
        // A one-word path covers its whole tree.
        XCTAssertEqual(ModelCommands.match(["meeting-prep", "transcript", "export", "4"]), "meeting-prep")
        XCTAssertEqual(ModelCommands.match(["meeting-prep", "evt-1", "--json"]), "meeting-prep")
    }

    /// A global flag's value is never a command word (codex review, #1886).
    func testGlobalFlagValuesAreConsumed() {
        XCTAssertEqual(ModelCommands.match(["--workspace", "digest", "digest", "generate"]), "digest generate")
        XCTAssertNil(ModelCommands.match(["--workspace", "ask", "sync", "--now"]))
        XCTAssertNil(ModelCommands.match(["--provider", "tune", "config", "get"]))
        XCTAssertEqual(ModelCommands.match(["digest", "--config", "generate", "generate"]), "digest generate")
    }

    /// Every string persistent flag of the Go root takes a value: each is in
    /// `globalValueFlags`.
    func testGlobalValueFlagsMatchTheGoRoot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("cmd/root.go")
        let text = try String(contentsOf: root, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"PersistentFlags\(\)\.String(?:VarP?|P?)\([^"]*"([a-z-]+)""#)
        let names = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { "--" + text[$0] }
        }
        XCTAssertFalse(names.isEmpty, "no string persistent flag found in cmd/root.go: is the pattern broken?")
        for name in names {
            XCTAssertTrue(ModelCommands.globalValueFlags.contains(name), "\(name) takes a value: add it to globalValueFlags")
        }
    }

    func testNonModelCommandsDoNotMatch() {
        XCTAssertNil(ModelCommands.match([]))
        XCTAssertNil(ModelCommands.match(["sync", "--now"]))
        XCTAssertNil(ModelCommands.match(["ai", "routing-status"]))
        XCTAssertNil(ModelCommands.match(["ai", "background", "allow", "--yes"]))
        XCTAssertNil(ModelCommands.match(["digest"]))
        XCTAssertNil(ModelCommands.match(["jira", "--account", "3", "boards", "select", "7"]))
        XCTAssertNil(ModelCommands.match(["actions", "trust", "x", "ask"]))
        XCTAssertNil(ModelCommands.match(["--", "digest", "generate"]))
    }
}
