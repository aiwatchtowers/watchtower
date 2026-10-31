import XCTest
@testable import WatchtowerSync

final class SeamTypesTests: XCTestCase {
    func testHubRouteExposesItsCloudKitScope() {
        XCTAssertEqual(HubRoute.cloudKit(.shared(ownerName: "_owner-acme")).cloudKitScope, .shared(ownerName: "_owner-acme"))
        XCTAssertNil(HubRoute.hostedRelay(macDeviceID: "mac-acme").cloudKitScope)
    }

    func testLinkInvitationNoneCarriesNoShares() {
        XCTAssertNil(LinkInvitation.none.dataShare)
        XCTAssertNil(LinkInvitation.none.relayShare)
    }

    func testTheCloudKitTransportIsALiveTransportAndTheFakeIsNot() throws {
        let transport = CloudKitTransport(
            store: try .inMemory(), scope: .private, hubID: HubZones.testHubID, role: .hub, entitlementPresent: { true },
            zoneAdmin: FakeZoneAdmin(),
            engineFactory: { _, _ in FakeSyncEngine() }, now: { Date() }, sleep: { _ in }
        )
        XCTAssertTrue((transport as Any) is any LiveTransport)
        XCTAssertFalse((InMemoryCloudTransport() as Any) is any LiveTransport)
    }
}
