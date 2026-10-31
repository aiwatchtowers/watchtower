import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

final class TransportFactoryTests: XCTestCase {
    func testACloudKitRouteBuildsAPhoneTransportOnItsScope() throws {
        let store = try TransportStore(path: ":memory:")
        let transport = try TransportFactory.cloudKit.make(
            .cloudKit(.shared(ownerName: "_owner-acme")), store, "hub-acme", nil)
        let cloud = try XCTUnwrap(transport as? CloudKitTransport)
        XCTAssertEqual(cloud.scope, .shared(ownerName: "_owner-acme"))
    }

    func testAHostedRelayRouteIsRefused() async throws {
        let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")
        let store = try TransportStore(path: ":memory:")
        XCTAssertThrowsError(try TransportFactory.cloudKit.make(route, store, "hub-acme", nil)) {
            XCTAssertEqual($0 as? UnsupportedRouteError, UnsupportedRouteError(route: route))
        }
        let record = CloudRecord(recordName: "wire-a", zone: .relay, kind: "wt", modifiedAt: Date(), payload: Data([1]))
        do {
            try await TransportFactory.cloudKit.sendDirectly(record, route, "hub-acme")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: route))
        }
    }

    func testAvailabilityIsTheEntitlementCheck() {
        XCTAssertEqual(TransportFactory.cloudKit.isAvailable(), CloudKitTransport.entitlementPresent())
    }
}
