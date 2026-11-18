import XCTest

/// Spec §7 (D11): every daemon stop the app makes is one of its internal
/// chains (restart, quit, compaction, Slack disconnect, wipe, onboarding
/// finish, the CLI binary store update), never the owner's choice to have no
/// background service. So each `sync stop` argv in the app's sources carries
/// `--internal`, which writes no `daemon.stopped` marker — an app stop never
/// shows the chat's "stopped" state.
final class DaemonManagerArgvScanTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    func testEveryAppSyncStopIsInternal() throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the scan must find the sources")
        let stop = try NSRegularExpression(pattern: #""sync"\s*,\s*"stop"(\s*,\s*"--internal")?"#)
        var found = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in stop.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found += 1
                let name = String(file.path.dropFirst(sources.path.count + 1))
                XCTAssertNotEqual(
                    match.range(at: 1).location, NSNotFound,
                    "\(name): a `sync stop` argv without \"--internal\" writes the owner's stopped marker"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(found, 3, "DaemonManager's stops are in the scan")
    }
}
