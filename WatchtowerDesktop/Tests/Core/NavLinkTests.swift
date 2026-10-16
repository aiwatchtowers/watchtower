import Foundation
import Testing
@testable import WatchtowerCore

@Suite("NavLink")
struct NavLinkTests {
    @Test("hidden, unknown and foreign links are rejected")
    func testNavLinkRejectsHiddenAndUnknown() {
        let allowed: Set<String> = ["calendar"]
        #expect(NavLink.destination(from: NavLink.url("calendar"), allowed: allowed) == "calendar")
        #expect(NavLink.destination(from: NavLink.url("projects"), allowed: allowed) == nil)
        #expect(NavLink.destination(from: NavLink.url("nope"), allowed: allowed) == nil)
        #expect(NavLink.destination(from: URL(string: "https://example.com/calendar")!, allowed: allowed) == nil)
    }
}
