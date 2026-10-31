import Foundation
import XCTest

final class SeamBoundaryTests: XCTestCase {
    func testOnlyTheCloudKitFolderImportsCloudKit() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            checked += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let imports = text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.hasPrefix("import CloudKit") }
            if imports {
                XCTAssertTrue(url.path.contains("/CloudKitTransport/"), "\(url.path) imports CloudKit outside CloudKitTransport/")
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
