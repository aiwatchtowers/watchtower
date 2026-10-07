import XCTest
@testable import WatchtowerDesktop

/// An inspector column opens at the width it was last dragged to (#401).
final class PersistedInspectorWidthTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let range: ClosedRange<Double> = 220...560

    override func setUpWithError() throws {
        suite = "PersistedInspectorWidthTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheColumnOpensAtItsIdealWidthByDefault() {
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 300)
    }

    func testAWidthStoredByAnEarlierRunIsReadAndClamped() {
        defaults.set(410.0, forKey: "w")
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 410)
        defaults.set(2000.0, forKey: "w")
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 560)
        defaults.set(10.0, forKey: "w")
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 220)
    }

    func testOnlyAWidthTheColumnCanBeDraggedToIsStored() {
        XCTAssertNil(PersistedInspectorWidth.widthToStore(0, range: range), "closed")
        XCTAssertNil(PersistedInspectorWidth.widthToStore(120, range: range), "mid-animation")
        XCTAssertEqual(PersistedInspectorWidth.widthToStore(219.6, range: range), 220)
        XCTAssertEqual(PersistedInspectorWidth.widthToStore(412.4, range: range), 412)
        XCTAssertEqual(PersistedInspectorWidth.widthToStore(700, range: range), 560)
    }
}
