import XCTest
@testable import WatchtowerCore

final class ConstantsClaudeBinaryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func config(_ claudePath: String) throws -> String {
        let path = dir.appendingPathComponent("config.yaml").path
        try "active_workspace: acme\nclaude_path: '\(claudePath)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func executable(_ name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testAnExecutableOverrideWins() throws {
        let bin = try executable("claude")
        XCTAssertEqual(Constants.claudeBinary(configPath: try config(bin)), .pinned(bin))
    }

    /// Review Focus 1: a directory, a missing file or a non-executable file
    /// is never launched; the lookup falls through to `findInPath`.
    func testAnUnusableOverrideFallsThrough() throws {
        let plain = dir.appendingPathComponent("plain").path
        try "x".write(toFile: plain, atomically: true, encoding: .utf8)
        for override in [dir.path, dir.appendingPathComponent("gone").path, plain] {
            let configPath = try config(override)
            XCTAssertNil(Constants.claudePathOverride(configPath: configPath), override)
            XCTAssertEqual(Constants.claudeBinary(configPath: configPath), Constants.findInPath("claude").map(ClaudeBinary.fallback), override)
        }
    }

    func testNoConfigFallsThrough() {
        let missing = dir.appendingPathComponent("none.yaml").path
        XCTAssertNil(Constants.claudePathOverride(configPath: missing))
        XCTAssertEqual(Constants.claudeBinary(configPath: missing), Constants.findInPath("claude").map(ClaudeBinary.fallback))
    }

    /// Go `fallbackPATH` mirrored: the owner's order first, missing
    /// well-known dirs appended, nothing duplicated, absent dirs skipped.
    func testWellKnownDirsAreAppendedOnce() {
        let present: Set<String> = ["/h/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/acme"]
        let merged = Constants.appendingWellKnownDirs(
            to: "/usr/bin:/opt/homebrew/bin", home: "/h", claudePath: "/opt/acme/claude"
        ) { present.contains($0) }
        XCTAssertEqual(merged, "/usr/bin:/opt/homebrew/bin:/h/.local/bin:/usr/local/bin:/opt/acme")
    }

    func testAnEmptyPathGetsJustTheWellKnownDirs() {
        let merged = Constants.appendingWellKnownDirs(to: "", home: "/h", claudePath: nil) { $0 == "/h/.local/bin" }
        XCTAssertEqual(merged, "/h/.local/bin")
    }
}
