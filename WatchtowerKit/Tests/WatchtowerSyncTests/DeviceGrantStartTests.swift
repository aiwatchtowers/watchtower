import Foundation
@testable import WatchtowerSync
import XCTest

/// #565: the hub's `start_sessions_granted` decides a phone's starts; an
/// older hub that does not write it keeps its own rule
/// (`start_sessions_allowed`), and an older phone keeps reading that field.
final class DeviceGrantStartTests: XCTestCase {
    private func grant(start: Bool, may: Bool?) -> DeviceGrant { // swiftlint:disable:this discouraged_optional_boolean
        DeviceGrant(
            deviceID: "phone-a", hubID: "hub", name: "iPhone", scope: .private, linked: true,
            typingAllowed: true, startSessionsAllowed: start, mayStartSessions: may
        )
    }

    private func roundTrip(_ grant: DeviceGrant) throws -> (DeviceGrant, [String: Any]) {
        let data = try RelayCoder.makeEncoder().encode(grant)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: data), json)
    }

    func testANewerHubsGrantDecidesAndTheOldFieldKeepsThePhonesToggle() throws {
        let (decoded, json) = try roundTrip(grant(start: true, may: false))
        XCTAssertFalse(decoded.mayStartSessions)
        XCTAssertTrue(decoded.startSessionsAllowed)
        XCTAssertEqual(json["start_sessions_granted"] as? Bool, false, "a newer hub always writes it")
        XCTAssertEqual(json["start_sessions_allowed"] as? Bool, true)
        XCTAssertTrue(try roundTrip(grant(start: true, may: true)).0.mayStartSessions)
    }

    func testAnOlderHubsRecordFallsBackToItsStartSessionsAllowed() throws {
        let (decoded, json) = try roundTrip(grant(start: true, may: nil))
        XCTAssertNil(json["start_sessions_granted"], "an older hub writes no such key")
        XCTAssertTrue(decoded.mayStartSessions)
        XCTAssertFalse(try roundTrip(grant(start: false, may: nil)).0.mayStartSessions)
    }
}
