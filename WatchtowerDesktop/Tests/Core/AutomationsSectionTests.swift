import XCTest
@testable import WatchtowerCore

final class AutomationsSectionTests: XCTestCase {
    func testTracksHiddenDropsTracksSection() {
        XCTAssertEqual(AutomationsSection.visible(tracksVisible: false), [.automations, .reactions])
        XCTAssertEqual(AutomationsSection.visible(tracksVisible: true), [.automations, .reactions, .tracks])
    }

    func testStoredTracksWithTracksHiddenFallsBackToAutomations() {
        XCTAssertEqual(AutomationsSection.resolve(stored: "tracks", tracksVisible: false), .automations)
        XCTAssertEqual(AutomationsSection.resolve(stored: "tracks", tracksVisible: true), .tracks)
    }

    func testUnknownOrMissingStoredValueFallsBackToAutomations() {
        XCTAssertEqual(AutomationsSection.resolve(stored: "nonsense", tracksVisible: true), .automations)
        XCTAssertEqual(AutomationsSection.resolve(stored: nil, tracksVisible: true), .automations)
        XCTAssertEqual(AutomationsSection.resolve(stored: "reactions", tracksVisible: false), .reactions)
    }
}
