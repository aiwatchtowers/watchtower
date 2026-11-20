import Foundation
import XCTest

/// A `List(selection: Binding<T?>)` matches its rows by tags of type `T`. A
/// row tagged `.tag(Optional(x))` (type `T?`, the form a Picker over an
/// optional wants) is not recognised on macOS 27: no row highlights and a
/// click selects nothing (the Connections service list, #2113).
final class ListSelectionTagTests: XCTestCase {
    func testNoListWithSelectionTagsRowsWithAnOptional() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = tests.deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("List(selection:") else { continue }
            scanned += 1
            if text.contains(".tag(Optional(") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 0, "no List(selection:) found — the scan is looking in the wrong place")
        XCTAssertEqual(offenders, [], "tag a List's rows with the bare value, not Optional(...)")
    }
}
