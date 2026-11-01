import WatchtowerSync
import XCTest

@testable import WatchtowerMobile

final class CloudKitLinkAccessTests: XCTestCase {
    private let access = CloudKitLinkAccess()

    /// The relay's access is its pairing slot (R19): iCloud has nothing to join or leave for it.
    func testAHostedRelayRouteJoinsAndLeavesWithoutACall() async throws {
        let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")
        try await access.join(.none, route: route, hubID: "hub-acme")
        try await access.leave(route: route, hubID: "hub-acme")
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
