import XCTest
@testable import WatchtowerCore

final class WatchmanStyleTests: XCTestCase {
    func testIconIsShield() {
        XCTAssertEqual(WatchmanStyle.icon, "shield.lefthalf.filled")
    }

    func testNoRetiredIconsInSources() throws {
        // Tests/Core/<file> -> WatchtowerDesktop/Sources
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var visited = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            visited += 1
            let name = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("moon.stars") { offenders.append("\(name): moon.stars") }
            if name.contains("Watchman"), text.contains("\"binoculars\"") { offenders.append("\(name): binoculars") }
        }
        XCTAssertGreaterThan(visited, 0, "the scan found no Swift sources; the path is wrong")
        XCTAssertEqual(offenders, [], "Watchman's icon is WatchmanStyle.icon")
    }
}
