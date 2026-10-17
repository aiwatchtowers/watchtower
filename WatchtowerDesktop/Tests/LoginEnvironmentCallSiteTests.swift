import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board #592: no Desktop code waits on the login-shell probe
/// (`Constants.resolvedEnvironment()`, up to 5 s) synchronously — not on the
/// main thread, not on a Swift-concurrency pool thread. Callers take
/// `resolvedEnvironmentAsync()` (async code) or `resolvedEnvironmentIfReady()`
/// (sync main-actor code that needs no login PATH).
final class LoginEnvironmentCallSiteTests: XCTestCase {
    /// The only lines allowed the blocking call, per file, with why.
    private static let allowed: [String: Set<String>] = [
        // The definition, the one shared off-pool resolve, and the CODEX_HOME
        // resolver (which `resolve()` runs off the pool).
        "WatchtowerCore/Utilities/Constants.swift": [
            "package nonisolated static func resolvedEnvironment() -> [String: String] {",
            "await ProcessPipes.offPool { resolvedEnvironment() }",
            "_ = resolvedEnvironment() // the launch-time resolve, cached"
        ],
        // `migrateAndOpen` runs off the main actor and off the pool (`offPool`).
        "Database/DatabaseManager.swift": [
            "process.environment = Constants.resolvedEnvironment()"
        ]
    ]

    func testNoBlockingLoginEnvironmentCall() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        // The bare name, called or passed as a function reference.
        let blocking = try NSRegularExpression(pattern: #"\bresolvedEnvironment\b"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let relative = String(url.standardizedFileURL.path.dropFirst(sources.standardizedFileURL.path.count + 1))
            let allowedLines = Self.allowed[relative] ?? []
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !allowedLines.contains(code) else { continue }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(blocking.firstMatch(in: line, range: range),
                             "\(relative):\(index + 1) waits on the login-shell probe; "
                                 + "use resolvedEnvironmentAsync() or resolvedEnvironmentIfReady()")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found too few sources: wrong path?")
    }
}

/// Board #592: the app's chat pool holds admission until the login
/// environment resolves, so no chat spawns without the owner's CODEX_HOME.
@MainActor
final class ChatSessionPoolWiringTests: XCTestCase {
    func testAppPoolHoldsAdmissionUntilTheLoginEnvironment() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = AppState().ensureChatSessionPool(manager)
        XCTAssertFalse(pool.admissionOpen, "held from the start")
        let opened = await waitForCondition(timeout: .seconds(10)) { pool.admissionOpen }
        XCTAssertTrue(opened, "opens once the login environment resolves")
        pool.stopPolicy()
        await pool.closeAll()
    }
}
