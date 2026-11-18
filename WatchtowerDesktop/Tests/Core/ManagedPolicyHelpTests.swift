import Foundation
@testable import WatchtowerCore
import XCTest

/// D21: every link to the IT page goes through `ManagedPolicyHelp`, whose URL
/// is the one Go's `policy.ITGuideURL` golden-writes to `docs/mdm/site.json`.
final class ManagedPolicyHelpTests: XCTestCase {
    private let desktop = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop

    func testOneConstant() throws {
        let sources = desktop.appendingPathComponent("Sources")
        let url = ManagedPolicyHelp.itGuideURL.absoluteString
        var holders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(url) { holders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(holders, ["ManagedPolicyHelp.swift"])
        // Both link sites of this version draw the shared link.
        for file in ["Views/Settings/OrganizationPolicySection.swift", "Views/Settings/ConnectionsSettings.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("ITGuideLink()"), file)
        }
    }

    func testURLEqualsGoConstant() throws {
        let site = desktop.deletingLastPathComponent().appendingPathComponent("docs/mdm/site.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: site)) as? [String: Any])
        XCTAssertEqual(ManagedPolicyHelp.itGuideURL.absoluteString, json["url"] as? String)
    }
}
