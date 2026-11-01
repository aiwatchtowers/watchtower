import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Whether this phone may use the hosted relay (relay client Phase 3, R18), and the dark ship: with no origin
/// nothing relay-shaped is built.
final class RelayAvailabilityTests: XCTestCase {
    private let configured = RelayConfig.parse(RelaySpies.origin)

    func testAvailableNeedsBothOriginAndSupport() throws {
        let origin = try XCTUnwrap(configured.origin)
        XCTAssertEqual(RelayAvailability.evaluate(config: configured, attestSupported: true), .available(origin))
        XCTAssertEqual(RelayAvailability.evaluate(config: configured, attestSupported: false), .off(.unsupportedDevice))
        XCTAssertEqual(RelayAvailability.evaluate(config: RelayConfig.parse(""), attestSupported: true), .off(.notConfigured))
        XCTAssertEqual(RelayAvailability.evaluate(config: RelayConfig.parse(nil), attestSupported: false), .off(.notConfigured))
    }

    /// The relay's `attestUnsupportedStaysOnCloudKit` scenario (R18): a device without App Attest has no relay,
    /// a v4 code offering both transports links over iCloud, and its hub row builds a CloudKit transport.
    func testAttestUnsupportedStaysOnCloudKit() async throws {
        let spies = RelaySpies(attestSupported: false)
        let relay = try spies.relay()
        XCTAssertEqual(relay.availability, .off(.unsupportedDevice))
        XCTAssertNil(try relay.session(), "no relay session on a device without App Attest")
        XCTAssertEqual(spies.keychain.operations, 0, "no relay identity in the Keychain")

        let code = LinkPayload(
            v: 4, hubID: TestHub.acme, macName: "Work Mac", ownerUser: "_owner-acme", nonce: "n",
            iat: 1_700_000_000, exp: 1_700_000_600, hubSigningKey: "sig", hubAgreementKey: "kx",
            transport: .cloudKit, transports: ["cloudkit", "relay"]
        )
        XCTAssertTrue(code.offersCloudKit)
        // The link the flow saves from that code with the relay off: no relay transport.
        let link = LinkRecord(
            hubID: code.hubID, macName: code.macName, scope: .private, ownerName: try XCTUnwrap(code.ownerUser),
            userRecordName: "_owner-acme", nonce: code.nonce, dataShareURL: nil, relayShareURL: nil,
            hubTransports: code.transports
        )
        XCTAssertEqual(link.route, .cloudKit(.private))

        let transports = TransportFactory.live(relay: relay)
        let transport = try transports.make(link.route, try TransportStore(path: ":memory:"), code.hubID, nil)
        XCTAssertTrue(transport is CloudKitTransport)
        let relayRoute = HubRoute.hostedRelay(macDeviceID: "mac-acme")
        XCTAssertThrowsError(try transports.make(relayRoute, try TransportStore(path: ":memory:"), code.hubID, nil)) {
            XCTAssertEqual($0 as? UnsupportedRouteError, UnsupportedRouteError(route: relayRoute))
        }
        XCTAssertEqual(spies.network.attempts, 0)
    }

    /// The dark ship: with an empty origin no part of the relay is even built, so no Keychain item, DeviceCheck
    /// call or connection exists, whatever the app asks of the relay.
    func testAnEmptyOriginBuildsNoRelayObject() async throws {
        for origin in [nil, "", "$(WATCHTOWER_RELAY_ORIGIN)"] {
            let spies = RelaySpies()
            let relay = try spies.relay(origin: origin)
            XCTAssertEqual(relay.availability, .off(.notConfigured))
            XCTAssertNil(try relay.session())
            XCTAssertFalse(relay.isBuilt)

            let transports = TransportFactory.live(relay: relay)
            let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")
            XCTAssertThrowsError(try transports.make(route, try TransportStore(path: ":memory:"), TestHub.acme, nil))
            let record = CloudRecord(recordName: "wire-a", zone: .relay, kind: "wt", modifiedAt: Date(), payload: Data([1]))
            do {
                try await transports.sendDirectly(record, route, TestHub.acme)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: route))
            }

            XCTAssertEqual(spies.partsBuilt, 0, "no relay part built")
            XCTAssertEqual(spies.attest.calls, 0, "no DeviceCheck call")
            XCTAssertEqual(spies.keychain.operations, 0, "no Keychain item")
            XCTAssertEqual(spies.network.attempts, 0, "no relay connection")
            XCTAssertFalse(relay.isBuilt, "no relay session")
        }
    }
}
