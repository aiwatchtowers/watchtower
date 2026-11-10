import XCTest
@testable import WatchtowerCore

/// The icon allowlist is one list on both sides: Go validates against
/// `internal/inboxfolders/icons.json`, the Desktop draws `InboxFolderIcons`.
final class InboxFolderIconsTests: XCTestCase {
    func testAllowlistEqualsTheGoFile() throws {
        // …/WatchtowerDesktop/Tests/Core/<this file> → the repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("internal/inboxfolders/icons.json")
        let goList = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertEqual(InboxFolderIcons.all, goList)
    }

    func testEmptyOrUnknownIconDrawsFolder() {
        XCTAssertEqual(InboxFolderIcons.symbol(for: ""), "folder")
        XCTAssertEqual(InboxFolderIcons.symbol(for: "trash"), "folder")
        XCTAssertEqual(InboxFolderIcons.symbol(for: "bolt"), "bolt")
    }
}
