import Foundation
import WatchtowerHostedRelay
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

    func testRelayRouteBuildsAHostedRelayTransportOnTheSharedSession() async throws {
        let spies = RelaySpies()
        let relay = try spies.relay()
        let transports = TransportFactory.live(relay: relay)
        let first = try transports.make(.hostedRelay(macDeviceID: "mac-acme"), try TransportStore(path: ":memory:"), "hub-a", nil)
        let second = try transports.make(.hostedRelay(macDeviceID: "mac-home"), try TransportStore(path: ":memory:"), "hub-b", nil)
        XCTAssertTrue(first is HostedRelayTransport)
        XCTAssertTrue(second is HostedRelayTransport)
        let session = try XCTUnwrap(try relay.session())
        XCTAssertTrue(try relay.session() === session, "one session for the process")
        XCTAssertEqual(spies.partsBuilt, 1, "the session is built once, shared by every relay transport")
        XCTAssertEqual(spies.network.attempts, 0, "building connects nothing")
        // A CloudKit route on the same factory stays CloudKit.
        let cloud = try transports.make(.cloudKit(.private), try TransportStore(path: ":memory:"), "hub-c", nil)
        XCTAssertTrue(cloud is CloudKitTransport)
    }

    func testRelayRouteWhenOffThrowsAndNeverFallsBack() async throws {
        for origin in [nil, RelaySpies.origin] {
            let spies = RelaySpies(attestSupported: false)
            let transports = TransportFactory.live(relay: try spies.relay(origin: origin))
            let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")
            XCTAssertThrowsError(try transports.make(route, try TransportStore(path: ":memory:"), "hub-a", nil)) {
                XCTAssertEqual($0 as? UnsupportedRouteError, UnsupportedRouteError(route: route))
            }
            let record = CloudRecord(recordName: "wire-a", zone: .relay, kind: "wt", modifiedAt: Date(), payload: Data([1]))
            do {
                try await transports.sendDirectly(record, route, "hub-a")
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: route))
            }
            XCTAssertEqual(spies.network.attempts, 0)
        }
    }

    func testEachRouteHasItsOwnStoreFile() throws {
        let paths = HubPaths(
            groupDirectory: URL(fileURLWithPath: "/g"), localDirectory: URL(fileURLWithPath: "/l"),
            recordingsBase: URL(fileURLWithPath: "/r")
        )
        XCTAssertEqual(paths.transportStorePath("hub-a", route: .cloudKit(.private)), "/l/hubs/hub-a/cloudkit-transport.sqlite")
        XCTAssertEqual(
            paths.transportStorePath("hub-a", route: .cloudKit(.shared(ownerName: "_owner-acme"))),
            "/l/hubs/hub-a/cloudkit-transport.sqlite"
        )
        XCTAssertEqual(paths.transportStorePath("hub-a", route: .hostedRelay(macDeviceID: "mac-acme")), "/l/hubs/hub-a/relay-transport.sqlite")
        XCTAssertEqual(paths.transportStorePath("hub-a"), paths.transportStorePath("hub-a", route: .cloudKit(.private)), "today's name")

        // A store a CloudKit transport bound refuses the relay: each route needs its own file (R12).
        let cloudKitStore = try TransportStore(path: ":memory:")
        _ = try cloudKitStore.adoptScope(.private, hubID: "hub-a")
        let transports = TransportFactory.live(relay: try RelaySpies().relay())
        XCTAssertThrowsError(try transports.make(.hostedRelay(macDeviceID: "mac-acme"), cloudKitStore, "hub-a", nil)) {
            XCTAssertEqual($0 as? TransportStoreError, .boundToAnotherRoute)
        }
    }

    func testAvailabilityIsTheEntitlementCheck() {
        XCTAssertEqual(TransportFactory.cloudKit.isAvailable(), CloudKitTransport.entitlementPresent())
    }
}
