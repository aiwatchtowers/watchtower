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
            let imports = text.split(separator: "\n").contains {
                $0.range(of: #"^(@\w+ )*import (\w+ )?CloudKit\b"#, options: .regularExpression) != nil
            }
            if imports {
                XCTAssertTrue(url.path.contains("/CloudKitTransport/"), "\(url.path) imports CloudKit outside CloudKitTransport/")
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testOnlyTheHostedRelayTargetsImportProtobuf() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let pattern = #"^(@\w+ )*import (\w+ )?(SwiftProtobuf|WatchtowerRelayProto|WatchtowerHostedRelay\w*|DeviceCheck)\b"#
        var checked = 0
        for folder in ["Sources/WatchtowerSync", "Sources/WatchtowerKit"] {
            let sources = root.appendingPathComponent(folder)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                checked += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n") where line.range(of: pattern, options: .regularExpression) != nil {
                    XCTFail("\(url.path) imports a hosted relay module: \(line)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
