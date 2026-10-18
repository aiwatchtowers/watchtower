import XCTest
@testable import WatchtowerDesktop

/// An unmounted connection's reason shows under its row without Go's
/// bookkeeping prefix.
final class QuickConnectionsDetailReasonTests: XCTestCase {
    func testPrefixesAreDropped() {
        XCTAssertEqual(
            QuickConnectionsDetail.reason("transport: Uses plain http, so its headers (a secret) would be sent unencrypted"),
            "Uses plain http, so its headers (a secret) would be sent unencrypted"
        )
        XCTAssertEqual(QuickConnectionsDetail.reason("tools: none of its tools is available"), "none of its tools is available")
        XCTAssertEqual(
            QuickConnectionsDetail.reason("reserved: The name \"watchtower__x\" is reserved for Watchtower's own tools"),
            "The name \"watchtower__x\" is reserved for Watchtower's own tools"
        )
        XCTAssertEqual(QuickConnectionsDetail.reason("refresh failed"), "refresh failed")
    }
}
