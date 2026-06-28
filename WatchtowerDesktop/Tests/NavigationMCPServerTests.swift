import XCTest
@testable import WatchtowerDesktop

final class NavigationMCPServerTests: XCTestCase {

    func testMCPServerInToolItems() {
        XCTAssertTrue(SidebarDestination.toolItems.contains(.mcpServer))
    }

    func testMCPServerTitle() {
        XCTAssertEqual(SidebarDestination.mcpServer.title, "MCP Server")
    }

    func testMCPServerIcon() {
        XCTAssertFalse(SidebarDestination.mcpServer.icon.isEmpty)
        XCTAssertEqual(SidebarDestination.mcpServer.icon, "terminal")
    }
}
