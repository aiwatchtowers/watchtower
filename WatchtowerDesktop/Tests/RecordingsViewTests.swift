import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

/// Pins the `externalSelection ?? $localSelectedID` hinge of the Events→
/// Recordings deep link: an external binding must win AND write back to the
/// host, so the Calendar screen's hoisted selection stays authoritative.
/// (The nil-external local round-trip needs a hosted view — @State outside a
/// view hierarchy is disconnected — so the plain-tab side is covered by the
/// RecordingsListView tap test writing through a supplied binding.)
@MainActor
final class RecordingsViewSelectionTests: XCTestCase {

    func test_externalBindingWinsAndWritesBack() {
        var external: Int64? = 42
        let view = RecordingsView(
            externalSelection: Binding(get: { external }, set: { external = $0 }))

        XCTAssertEqual(view.selectedID.wrappedValue, 42, "external selection must win")

        view.selectedID.wrappedValue = nil
        XCTAssertNil(external, "deselect (and the delete path) must write back to the host")

        view.selectedID.wrappedValue = 7
        XCTAssertEqual(external, 7)
    }
}
