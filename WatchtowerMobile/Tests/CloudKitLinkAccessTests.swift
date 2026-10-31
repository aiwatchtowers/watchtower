import WatchtowerSync
import XCTest

@testable import WatchtowerMobile

final class CloudKitLinkAccessTests: XCTestCase {
    private let access = CloudKitLinkAccess()

    func testAHostedRelayRouteIsRefused() async {
        let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")
        do {
            try await access.join(.none, route: route, hubID: "hub-acme")
            XCTFail("join should refuse a hosted relay route")
        } catch {
            XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: route))
        }
        do {
            try await access.leave(route: route, hubID: "hub-acme")
            XCTFail("leave should refuse a hosted relay route")
        } catch {
            XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: route))
        }
    }

    func testAnInvitationWithoutShareURLsIsRefusedBeforeAnyCall() async {
        let invitation = LinkInvitation(dataShare: nil, relayShare: "https://www.icloud.com/share/x")
        do {
            try await access.join(invitation, route: .cloudKit(.shared(ownerName: "_owner-acme")), hubID: "hub-acme")
            XCTFail("join should refuse an incomplete invitation")
        } catch {
            XCTAssertEqual(error as? LinkAccessError, .invalidInvitation)
        }
    }

    func testAPrivateRouteJoinsAndLeavesWithoutACall() async throws {
        try await access.join(.none, route: .cloudKit(.private), hubID: "hub-acme")
        try await access.leave(route: .cloudKit(.private), hubID: "hub-acme")
    }
}
