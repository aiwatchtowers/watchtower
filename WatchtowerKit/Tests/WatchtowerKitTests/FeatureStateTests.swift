import GRDB
import WatchtowerKit
import XCTest

final class FeatureStateTests: XCTestCase {

    // MARK: - Wire format (FROZEN)

    /// The exact bytes the desktop publishes for one feature — sorted keys,
    /// boolean as SQLite integer. Changing this payload breaks phone/desktop
    /// interop; the desktop side pins the same literal in
    /// SlicePublisherTests.
    func testDecodesFromFrozenPayloadFixture() throws {
        let disabled = try RowPayloadCoder.row(from: Data(#"{"enabled":0,"id":"targets"}"#.utf8))
        let state = FeatureState(row: disabled)
        XCTAssertEqual(state.id, "targets")
        XCTAssertFalse(state.enabled)

        let enabled = try RowPayloadCoder.row(from: Data(#"{"enabled":1,"id":"secretary-inbox"}"#.utf8))
        let enabledState = FeatureState(row: enabled)
        XCTAssertEqual(enabledState.id, "secretary-inbox")
        XCTAssertTrue(enabledState.enabled)
    }

    /// Degenerate row without the flag: fails open (enabled), matching the
    /// absent-slice default.
    func testMissingEnabledColumnFailsOpen() throws {
        let row = try RowPayloadCoder.row(from: Data(#"{"id":"chat"}"#.utf8))
        XCTAssertTrue(FeatureState(row: row).enabled)
    }

    // MARK: - FeatureVisibility semantics

    /// Empty replica (older desktop never published the kind): all visible.
    func testEmptyStatesEverythingVisible() {
        let visibility = FeatureVisibility(states: [])
        XCTAssertEqual(visibility, .allVisible)
        XCTAssertTrue(visibility.isVisible(featureID: "targets"))
        XCTAssertTrue(visibility.isVisible(featureID: nil))
    }

    func testDisabledFeatureHidesOnlyItself() {
        let visibility = FeatureVisibility(states: [
            FeatureState(id: "targets", enabled: false),
            FeatureState(id: "tracks", enabled: true)
        ])
        XCTAssertFalse(visibility.isVisible(featureID: "targets"))
        XCTAssertTrue(visibility.isVisible(featureID: "tracks"))
        XCTAssertTrue(visibility.isVisible(featureID: "briefing"))
    }

    /// Unknown ids in the slice (a future desktop's new feature) are inert:
    /// they hide nothing the phone maps today.
    func testUnknownFeatureIDsAreIgnored() {
        let visibility = FeatureVisibility(states: [
            FeatureState(id: "some-future-feature", enabled: false)
        ])
        XCTAssertTrue(visibility.isVisible(featureID: "targets"))
        XCTAssertTrue(visibility.isVisible(featureID: "chat"))
        // The unknown id itself IS honored if anything ever maps to it.
        XCTAssertFalse(visibility.isVisible(featureID: "some-future-feature"))
    }

    /// A surface mapped to no registry feature (nil) is never hideable,
    /// whatever the slice says.
    func testNilFeatureIDAlwaysVisible() {
        let visibility = FeatureVisibility(states: [
            FeatureState(id: "targets", enabled: false),
            FeatureState(id: "chat", enabled: false)
        ])
        XCTAssertTrue(visibility.isVisible(featureID: nil))
    }
}
