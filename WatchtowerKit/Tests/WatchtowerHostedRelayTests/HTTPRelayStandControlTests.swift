import WatchtowerRelayProto
import XCTest

/// The stand control's parsing of a 409 body (no network: the stand itself is in the interop tests).
final class HTTPRelayStandControlTests: XCTestCase {
    func testConflictBodyNamesTheErrorCode() {
        XCTAssertEqual(HTTPRelayStandControl.code(in: "add slot: entitlement_inactive"), .entitlementInactive)
        XCTAssertEqual(HTTPRelayStandControl.code(in: "set hub readers: forbidden"), .forbidden)
        XCTAssertEqual(HTTPRelayStandControl.code(in: "add slot: slot_replacement_limit"), .slotReplacementLimit)
    }

    func testUnknownConflictBodyIsUnspecified() {
        XCTAssertEqual(HTTPRelayStandControl.code(in: "add slot: something_new"), .unspecified)
        XCTAssertEqual(HTTPRelayStandControl.code(in: ""), .unspecified)
    }
}
