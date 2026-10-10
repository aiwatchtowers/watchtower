import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// The app side Settings → Mobile drives, without an AppState: the toggle
/// flag, the hub and the storage error.
@MainActor
final class FakeMobileSettingsHost: MobileSettingsHost {
    var isMobileSyncEnabled: Bool
    var mobileHub: MobileHubService?
    var mobileHubInitError: String?
    private(set) var setCalls: [Bool] = []

    init(enabled: Bool) {
        isMobileSyncEnabled = enabled
    }

    func setMobileSyncEnabled(_ enabled: Bool) {
        setCalls.append(enabled)
        isMobileSyncEnabled = enabled
    }
}

/// A real hub on a stub transport and its link center on a fake share
/// service and a fake clock — the objects Settings → Mobile reads.
@MainActor
final class MobileSettingsFixture {
    let dbPath: String
    let dbPool: DatabasePool
    let sidecar: HubSyncState
    let transport: StubHubTransport
    let shares: FakeShareService
    let clock: LinkTestClock
    let hub: MobileHubService
    let center: MobileLinkCenter
    let host: FakeMobileSettingsHost

    /// `shareAccount` is what the link center's probe reads; the hub's own
    /// transport stays available, so only the account gates the QR.
    /// `phones` are linked before the center loads its list.
    init(
        shareAccount: CloudAvailability = .available,
        enabled: Bool = true,
        phones: [(id: String, scope: DeviceScope, user: String)] = []
    ) throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        sidecar = try HubSyncState.inMemory()
        for phone in phones {
            try sidecar.linkTestDevice(phone.id, scope: phone.scope, userRecordName: phone.user)
        }
        transport = StubHubTransport()
        shares = FakeShareService(account: shareAccount)
        clock = LinkTestClock()
        let host = FakeMobileSettingsHost(enabled: enabled)
        self.host = host
        let publisher = SlicePublisher(
            dbPool: dbPool, state: sidecar, transport: transport, sources: [],
            timing: .init(tick: .milliseconds(20), fastWindow: .milliseconds(10), fastSpacing: .milliseconds(10))
        )
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme"
        )
        hub = MobileHubService(
            transport: transport, publisher: publisher, processor: processor, sidecar: sidecar,
            hostInfo: testHostInfo(), relayIdleInterval: .milliseconds(20), relayActiveInterval: .milliseconds(20),
            availabilityReprobeInterval: .milliseconds(20)
        ) { [weak host] in host?.isMobileSyncEnabled ?? false }
        let clock = self.clock
        center = MobileLinkCenter(
            sidecar: sidecar, shares: shares, macName: "Mac acme", ownerUser: { "_owner-acme" },
            nudge: { _ in },
            now: { clock.now },
            // The center's own expiry timer parks: only the code under test closes.
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        center.attach(to: hub)
        host.mobileHub = hub
    }

    func makeModel(entitlementPresent: Bool = true, flavor: HubFlavor = .default) -> MobileSettingsViewModel {
        let clock = self.clock
        return MobileSettingsViewModel(
            host: host, entitlementPresent: entitlementPresent, flavor: flavor,
            now: { clock.now },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
    }

    func startHub() async {
        await hub.start()
        XCTAssertEqual(hub.status, .running)
    }

    func tearDown() async {
        await center.closeLink(reason: .sheetClosed)
        hub.stop()
        await hub.waitUntilStopped()
        TestDatabase.cleanup(path: dbPath)
    }
}
