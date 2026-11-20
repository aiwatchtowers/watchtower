import SwiftUI
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The #2114 frames of the tour: Close without answering on the ask forms, a dismissal on its way and the ask once
/// closed. The confirmation is presented as an alert, which iOS 26 draws outside drawHierarchy; its words are
/// asserted in `AskDismissTests`.
extension ScreenshotTourTests {
    /// `SHOTS_ONLY=ask-dismiss` runs `testTheAskDismissShots` alone.
    static let onlyAskDismiss = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "ask-dismiss"

    func testTheAskDismissShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyAskDismiss else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=ask-dismiss")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, demo) = try makeDemoRoot()
        let env = root.env
        try await poll({ Self.isHydrated(env) }, "the demo seed hydrated")
        let host = ScreenshotHost(directory: dir, env: env, linking: root.linking)
        func ask(_ id: Int64) -> some View {
            NavigationStack { AskView(replica: env.workbenchReplica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: id) }
        }

        try await host.capture("ask-dismiss-1-question", ask(109))
        try await host.capture("ask-dismiss-2-review", ask(110))

        // On its way: the check ask closed with a note.
        env.askDrafts.update(111) { $0.note = "Not needed this sprint" }
        let check = try XCTUnwrap(env.workbenchReplica.snapshot.asks.first { $0.id == 111 })
        let sent = try await env.askAnswerer.sendDismissal(check)
        XCTAssertTrue(sent)
        try await host.capture("ask-dismiss-3-sending", ask(111))

        // Closed: the replica's dismissed ask.
        let now = Date()
        let closed = DemoSeed.JSON.ask(153, workbench: DemoSeed.acmeID, [
            "kind": "check", "status": "answered", "title": "Check the archive view",
            "answered_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60)),
            "answer": ["verdict": "", "answers": [Any](), "checklist": [Any](), "comments": [Any](),
                       "dismissed": true, "note": "Not needed this sprint"]
        ])
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: now))
        try await sealing.save([try DemoSeed.record(kind: .ownerAsk, id: 153, json: closed, modifiedAt: now)])
        _ = await env.refresh(.pull)
        try await poll({ env.workbenchReplica.snapshot.asks.contains { $0.id == 153 } }, "the dismissed ask arrived")
        try await host.capture("ask-dismiss-4-closed", ask(153))

        let written = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasPrefix("ask-dismiss-") }
        XCTAssertEqual(written.count, 8)
    }
}
