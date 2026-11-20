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

    /// L1–L8 and L10 on the built views, from demo records republished per state: session 10's chat with its live
    /// block (running step, steps open, between tools, a failed read), a working session with no chat record yet
    /// (Loading), the tower's heartbeat gone stale, "Board lanes" behind a permission card, a subagent's own chat with
    /// its sidechain's block (`SessionChatView`), and session 10 idle. L9 (the agents sheet) is Task 8's
    /// `workchat-agents` tour. Returns the frames.
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
        let route = SessionChatRoute(sessionID: 10, agentID: nil)
        env.workchatSteps.toggle(route, WorkchatLiveLine.StepsWatch(chat: probe.chat, working: true, cardShown: false))
        try await workchat("workchat-live-real-L2")
        env.workchatSteps.close(route)
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
        try await captureSubagentLine(env, now: now, host: host) { records, what, done in try await publish(records, what, until: done) }
        // L10: session 10 idle.
        let idle = try DemoSeed.record(kind: .terminalSession, id: 10, json: DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, [
            "title": "Session report", "state_kind": "waiting_on_ask", "state_caption": "Your turn", "state_tone": "orange",
            "state_glyph": "arrowshape.turn.up.left.fill", "target_id": 430,
            "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ]), modifiedAt: Date())
        try await publish([idle], "L10 idle") { snapshot().session(10)?.stateKind == .waitingOnAsk }
        try await workchat("workchat-live-real-L10")
        return 9
    }

    /// L8: a subagent's own chat (`SessionChatView`) with its sidechain's live block.
    private func captureSubagentLine(
        _ env: AppEnvironment,
        now: Date,
        host: ScreenshotHost,
        publish: ([CloudRecord], String, @escaping @MainActor () -> Bool) async throws -> Void
    ) async throws {
        // L8: a subagent's chat, its own live block (the sidechain's step).
        let subagent = SessionChatRoute(sessionID: 10, agentID: "demo-3", toolUseID: "toolu_demo3")
        let at: (TimeInterval) -> String = { now.addingTimeInterval(-$0).ISO8601Format() }
        let grep: [String: Any] = ["id": "toolu_g1", "tool": "Grep", "summary": "\"func LiveOf\" in internal/", "started_at": at(4), "more": 0]
        let subagentJSON: [String: Any] = [
            "session_id": 10, "agent_id": "demo-3", "live": true, "entries_more": 0, "live_version": 1,
            "entries": [
                ["id": "s1", "kind": "owner", "at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60)), "text": "Recon the DB layer"],
                ["id": "s2", "kind": "agent", "at": DemoSeed.JSON.stamp(now.addingTimeInterval(-20)),
                 "text": "Looking for where the live snapshot is read and who calls it."]
            ],
            "activity_live": [
                "observed_at": at(1), "conversation": "demo-sidechain", "turn_at": at(60), "turn_active": true,
                "current": grep, "agents": [] as [Any], "agents_state": "known", "agents_more": 0, "steps": [grep], "steps_more": 0
            ] as [String: Any]
        ]
        let subagentRecord = CloudRecordFactory.record(for: SliceRecord(
            kind: .sessionChat, id: "10-demo-3", modifiedAt: Date(),
            payload: try JSONSerialization.data(withJSONObject: subagentJSON, options: [.sortedKeys])
        ))
        let subagentProbe = SessionChatViewModel(sessionID: 10, agentID: "demo-3", toolUseID: "toolu_demo3", store: env.store,
                                                 requester: env.chatRequests)
        subagentProbe.appeared()
        try await publish([subagentRecord], "L8 record") { subagentProbe.chat?.activityLive != nil }
        subagentProbe.disappeared()
        try await host.capture("workchat-live-real-L8", NavigationStack {
            SessionChatView(replica: env.workbenchReplica, route: subagent, store: env.store, requester: env.chatRequests)
        }, settle: .milliseconds(1_500))
    }
}
