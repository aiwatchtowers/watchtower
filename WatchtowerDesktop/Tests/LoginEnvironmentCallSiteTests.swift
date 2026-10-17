import XCTest

/// Board #592: no Desktop code waits on the login-shell probe
/// (`Constants.resolvedEnvironment()`, up to 5 s) synchronously — not on the
/// main thread, not on a Swift-concurrency pool thread. Callers take
/// `resolvedEnvironmentAsync()` (async code) or `resolvedEnvironmentIfReady()`
/// (sync main-actor code that needs no login PATH).
final class LoginEnvironmentCallSiteTests: XCTestCase {
    /// Files allowed the blocking call, with why.
    private static let allowed: Set<String> = [
        // The definition and the launch-time prewarm.
        "WatchtowerCore/Utilities/Constants.swift",
        // Runs on its own off-pool thread (`offPool`), never main or the pool.
        "Database/DatabaseManager.swift"
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
            guard !Self.allowed.contains(relative) else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(blocking.firstMatch(in: line, range: range),
                             "\(relative):\(index + 1) waits on the login-shell probe; "
                                 + "use resolvedEnvironmentAsync() or resolvedEnvironmentIfReady()")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found too few sources: wrong path?")
    }
}
