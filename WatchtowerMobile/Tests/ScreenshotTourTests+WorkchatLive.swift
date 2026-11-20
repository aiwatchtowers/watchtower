import SwiftUI
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The #2112 phone live-line frames (spec 2026-11-20 "Phone Workchat: the live line"): the mockups L1–L10 and the
/// built `WorkchatView` beside them.
extension ScreenshotTourTests {
    /// `SHOTS_ONLY=workchat-live` runs `testTheWorkchatLiveShots` alone.
    static let onlyWorkchatLive = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "workchat-live"

    /// #2112: static mockups of the live line, the steps slot and the live agents sheet, then the real views
    /// (`make mobile-shots SHOTS_ONLY=workchat-live`).
    func testTheWorkchatLiveShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyWorkchatLive else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=workchat-live")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, demo) = try makeDemoRoot()
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        for (name, view) in WorkchatLiveMockups.frames {
            try await host.capture(name, view, settle: .milliseconds(1_500))
        }
        let real = try await captureWorkchatLiveReal(root.env, demo: demo, host: host)
        let written = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasPrefix("workchat-live-") }
        XCTAssertEqual(written.count, 2 * (WorkchatLiveMockups.frames.count + real))
    }

    /// L1–L7 and L10 on the built `WorkchatView`, from demo records republished per state: session 10's chat with its
    /// live block (running step, steps open, between tools, a failed read), a working session with no chat record
    /// yet (Loading), the tower's heartbeat gone stale, "Board lanes" behind a permission card, and session 10 idle.
    /// L8 (a subagent's chat) and L9 (the agents sheet, Task 8) have no capture here. Returns the frames.
    private func captureWorkchatLiveReal(_ env: AppEnvironment, demo: DemoHub, host: ScreenshotHost) async throws -> Int {
        try await poll({ Self.isHydrated(env) }, "the demo seed hydrated")
        let now = Date()
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: now))
        let seed = try DemoSeed.records(now: now)
        let probe = WorkchatView.chatModel(sessionID: 10, store: env.store, requester: env.chatRequests)
        probe.appeared()
        defer { probe.disappeared() }
        let snapshot = { env.workbenchReplica.snapshot }
        func publish(_ records: [CloudRecord], _ what: String, until done: @escaping @MainActor () -> Bool) async throws {
            try await sealing.save(records)
            _ = await env.refresh(.pull)
            try await poll(done, what)
        }
        func chat10(_ edit: (inout [String: Any]) -> Void) throws -> CloudRecord {
            var json = DemoSeed.workingChatPayload(now: now)
            var live = json["activity_live"] as? [String: Any] ?? [:]
            edit(&live)
            json["activity_live"] = live.isEmpty ? nil : live
            if live.isEmpty { json["live_error"] = "Activity unavailable" }
            return try DemoSeed.record(kind: .sessionChat, id: 10, json: json, modifiedAt: Date())
        }
        func workchat(_ name: String, _ id: Int64 = 10) async throws {
            try await host.capture(name, NavigationStack {
                WorkchatView(replica: env.workbenchReplica, sessionID: id, store: env.store, requester: env.chatRequests)
            }, settle: .milliseconds(1_500))
        }

        // L1: the seed's live block, its dates from this run.
        try await publish([try chat10 { _ in }], "L1 block") { probe.chat?.activityLive?.current != nil }
        try await workchat("workchat-live-real-L1")
        // L2: the owner opened the steps.
        env.workchatSteps.toggle(10, conversation: probe.chat?.activityLive?.conversation)
        try await workchat("workchat-live-real-L2")
        env.workchatSteps.close(10)
        // L3: between tools.
        try await publish([try chat10 { $0["current"] = nil; $0["latest"] = nil }], "L3 block") {
            probe.chat?.activityLive?.current == nil && probe.chat?.activityLive != nil
        }
        try await workchat("workchat-live-real-L3")
        // L5: the hub's read failed.
        try await publish([try chat10 { $0.removeAll() }], "L5 error") { probe.chat?.liveError != nil }
        try await workchat("workchat-live-real-L5")
        // L4: a working session with no chat record yet.
        let fresh = try DemoSeed.record(kind: .terminalSession, id: 90, json: DemoSeed.JSON.session(90, workbench: DemoSeed.acmeID, [
            "title": "Live line", "state_kind": "working", "state_caption": "Working", "state_tone": "green",
            "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-194))
        ]), modifiedAt: Date())
        try await publish([fresh], "L4 session") { snapshot().session(90) != nil }
        try await workchat("workchat-live-real-L4", 90)
        // L6: the tower stopped sending: its heartbeat 40 min old.
        try await publish([try chat10 { _ in }], "L6 block") { probe.chat?.activityLive?.current != nil }
        let stale = try XCTUnwrap(DemoSeed.records(now: now.addingTimeInterval(-2_400)).first { $0.recordName == HeartbeatPayload.recordName })
        try await publish([stale], "the demo Mac fell asleep") { env.macReachability(now: Date()) != .online }
        try await workchat("workchat-live-real-L6")
        let beat = try XCTUnwrap(seed.first { $0.recordName == HeartbeatPayload.recordName })
        try await publish([beat], "the demo Mac woke") { env.macReachability(now: Date()) == .online }
        // L7: "Board lanes" behind a permission card, its live block present.
        var json12 = DemoSeed.workingChatPayload(now: now)
        json12["session_id"] = 12
        let request = try DemoSeed.record(
            kind: .permissionRequest, id: 7,
            json: permissionRequestJSON(7, session: 12, ["summary": "rm -rf build/mobile-shots"]), modifiedAt: now
        )
        try await publish([request, try DemoSeed.record(kind: .sessionChat, id: 12, json: json12, modifiedAt: Date())],
                          "L7 card") { snapshot().pendingPermission(for: 12) != nil }
        try await workchat("workchat-live-real-L7", 12)
        try await sealing.delete(recordNames: [request.recordName], in: request.zone)
        // L10: session 10 idle.
        let idle = try DemoSeed.record(kind: .terminalSession, id: 10, json: DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, [
            "title": "Session report", "state_kind": "waiting_on_ask", "state_caption": "Your turn", "state_tone": "orange",
            "state_glyph": "arrowshape.turn.up.left.fill", "target_id": 430,
            "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ]), modifiedAt: Date())
        try await publish([idle], "L10 idle") { snapshot().session(10)?.stateKind == .waitingOnAsk }
        try await workchat("workchat-live-real-L10")
        return 8
    }
}
