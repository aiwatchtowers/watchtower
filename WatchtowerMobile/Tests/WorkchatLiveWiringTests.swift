import SwiftUI
import UIKit
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The live line's wiring on the built `WorkchatView` over the demo app (#2112): the screen's state changes reach the
/// steps memory, and the demo's requester says no hub echoes its `open_id`.
@MainActor
final class WorkchatLiveWiringTests: XCTestCase {
    private func demoRoot() throws -> (AppEnvironment, InMemoryCloudTransport, UserDefaults) {
        let defaults = try makeDefaults()
        let env = AppEnvironment(backend: .inMemoryDemo, defaults: defaults)
        var primary: InMemoryCloudTransport?
        for hub in DemoSeed.hubs {
            let transport = InMemoryCloudTransport()
            if hub == DemoSeed.primary { primary = transport }
            let session = try HubSession(
                transport: transport, replicaPath: try makeReplicaPath(), backend: .inMemoryDemo, hubID: hub.hubID,
                defaults: defaults, recordingsDirectory: try makeRecordingsDirectory()
            )
            addTeardownBlock { @MainActor in session.stop() }
            env.add(session)
        }
        env.activate(DemoSeed.primary.hubID)
        _ = try AppRoot.demo(env, defaults: defaults)
        return (env, try XCTUnwrap(primary), defaults)
    }

    private func host(_ view: some View, env: AppEnvironment) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view.environment(env))
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        return window
    }

    func testTheTurnEndingOnScreenClosesTheSteps() async throws {
        let (env, transport, defaults) = try demoRoot()
        try await poll({ env.workbenchReplica.snapshot.session(10)?.stateKind == .working }, "the demo seed hydrated")
        XCTAssertFalse(env.chatRequests.hubEchoesOpenID, "the demo's records answer no request")
        let route = SessionChatRoute(sessionID: 10, agentID: nil)
        _ = try host(NavigationStack {
            WorkchatView(replica: env.workbenchReplica, sessionID: 10, store: env.store, requester: env.chatRequests)
        }, env: env)
        env.workchatSteps.toggle(route, WorkchatLiveLine.StepsWatch(chat: nil, working: true, cardShown: false))
        XCTAssertTrue(env.workchatSteps.isOpen(route))

        let now = Date()
        let sealing = DemoSeed.hubTransport(inner: transport, seq: DemoSeed.hubSeq(defaults: defaults, now: now))
        let idle = try DemoSeed.record(kind: .terminalSession, id: 10, json: DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, [
            "title": "Session report", "state_kind": "waiting_on_ask", "state_caption": "Your turn", "state_tone": "orange",
            "state_at": DemoSeed.JSON.stamp(now)
        ]), modifiedAt: now)
        try await sealing.save([idle])
        _ = await env.refresh(.pull)
        try await poll({ env.workbenchReplica.snapshot.session(10)?.stateKind == .waitingOnAsk }, "the idle state arrived")
        try await poll({ !env.workchatSteps.isOpen(route) }, "the screen's change did not reach the steps memory")
    }
}
