import XCTest
@testable import WatchtowerCore

final class WatchmanStyleTests: XCTestCase {
    func testIconIsBinoculars() {
        XCTAssertEqual(WatchmanStyle.icon, "binoculars")
    }

    func testNoMoonStarsInWatchmanSources() throws {
        // Tests/Core/<file> -> WatchtowerDesktop/Sources
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name.contains("Watchman") || name.hasPrefix("EmptyStateCopy") || name.contains("Tray")
            else { continue }
            if try String(contentsOf: url, encoding: .utf8).contains("moon.stars") { offenders.append(name) }
        }
        XCTAssertEqual(offenders, [], "Watchman's icon is WatchmanStyle.icon, not moon.stars")
    }
}
