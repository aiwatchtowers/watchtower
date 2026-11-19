import SwiftUI
import UIKit
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The #2065 workchat-agents frames of the tour (spec 2026-11-19 §1–§2): the mockups and the built views beside them.
extension ScreenshotTourTests {
    /// `SHOTS_ONLY=workchat-agents` runs `testTheWorkchatAgentsShots` alone: the agents sheet mockups (#2065).
    static let onlyWorkchatAgents = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "workchat-agents"

    /// #2065 (spec 2026-11-19 §1–§2): static mockups of the session chat without subagent cards, its agents button
    /// and the agents sheet, P1–P4 (`make mobile-shots SHOTS_ONLY=workchat-agents`).
    func testTheWorkchatAgentsShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyWorkchatAgents else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=workchat-agents")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, demo) = try makeDemoRoot()
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let frames: [(String, AnyView)] = [
            ("workchat-phone-P1", AnyView(WorkchatAgentsMockups.p1)),
            ("workchat-phone-P2", AnyView(WorkchatAgentsMockups.p2)),
            ("workchat-phone-P3", AnyView(WorkchatAgentsMockups.p3)),
            ("workchat-phone-P4", AnyView(WorkchatAgentsMockups.p4))
        ]
        for (name, view) in frames {
            try await host.capture(name, view, settle: .milliseconds(1_500))
        }
        let real = try await captureWorkchatAgentsReal(root.env, demo: demo, host: host)
        let written = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasPrefix("workchat-phone-") }
        XCTAssertEqual(written.count, 2 * (frames.count + real))
    }

    /// P1–P4 on the built views, beside the mockups: the demo session 10's chat slice republished with the mockups'
    /// agents as subagent markers (2 running and 9 finished; 9 finished; none), the real `WorkchatView` for the
    /// toolbar button, and the real `WorkchatAgentsSheet` presented as a sheet over it (P2, P3-sheet; the view's own
    /// `showsAgents` is private state, so the sheet is presented by the capture's container, with the same detents).
    /// P3 publishes the session as idle (its turn over); P4 puts the seeded working state back. Returns the frames.
    private func captureWorkchatAgentsReal(_ env: AppEnvironment, demo: DemoHub, host: ScreenshotHost) async throws -> Int {
        try await poll({ Self.isHydrated(env) }, "the demo seed hydrated")
        let now = Date()
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: now))
        let probe = WorkchatView.chatModel(sessionID: 10, store: env.store, requester: env.chatRequests)
        probe.appeared()
        defer { probe.disappeared() }
        func marker(_ index: Int, _ agent: WorkchatAgentsMockups.Agent, status: String) -> [String: Any] {
            ["id": "m\(index)", "kind": "subagent", "at": DemoSeed.JSON.stamp(now.addingTimeInterval(-600)), "text": "",
             "subagent": ["agent_id": "a\(index)", "tool_use_id": "toolu_\(index)", "type": agent.type,
                          "description": agent.description, "status": status]]
        }
        func publish(
            _ name: String,
            markers: [[String: Any]],
            session: CloudRecord? = nil,
            state: TerminalSessionState.Kind = .working
        ) async throws -> [SessionChat.Entry] {
            var json = DemoSeed.workingChatPayload(now: now)
            let dialog = (json["entries"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String != "subagent" }
            json["entries"] = dialog + markers
            let chat = try DemoSeed.record(kind: .sessionChat, id: 10, json: json, modifiedAt: Date())
            try await sealing.save([chat] + (session.map { [$0] } ?? []))
            _ = await env.refresh(.pull)
            try await poll({
                probe.chat?.entries.filter { $0.subagent != nil }.count == markers.count
                    && env.workbenchReplica.snapshot.session(10)?.stateKind == state
            }, name)
            return probe.chat?.entries ?? []
        }
        func workchat(_ name: String, sheet entries: [SessionChat.Entry]? = nil) async throws {
            try await host.capture(name, NavigationStack {
                WorkchatView(replica: env.workbenchReplica, sessionID: 10, store: env.store, requester: env.chatRequests)
            }
            .sheet(isPresented: .constant(entries != nil)) {
                if let entries {
                    WorkchatAgentsSheet(agents: WorkchatAgents(entries: entries, sessionID: 10),
                                        disclosure: .constant(.automatic), onOpen: { _ in }, onClose: {})
                        // Shot only, as in the mockups: drawHierarchy draws no blur, so glass shows the chat.
                        .presentationBackground(Color(.systemBackground))
                }
            }, settle: .milliseconds(1_500))
        }
        let running = WorkchatAgentsMockups.working.enumerated().map { marker($0.offset, $0.element, status: "running") }
        let finished = WorkchatAgentsMockups.done.enumerated().map { marker(10 + $0.offset, $0.element, status: "finished") }
        let working = try await publish("P1/P2 markers", markers: running + finished)
        try await workchat("workchat-phone-real-P1")
        try await workchat("workchat-phone-real-P2", sheet: working)
        let idle = try DemoSeed.record(kind: .terminalSession, id: 10, json: DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, [
            "title": "Session report", "state_kind": "stopped", "state_caption": "Idle", "state_tone": "secondary",
            "state_glyph": "pause.fill", "target_id": 430, "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60)),
            "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ]), modifiedAt: Date())
        let done = try await publish("P3 markers", markers: finished, session: idle, state: .stopped)
        try await workchat("workchat-phone-real-P3")
        try await workchat("workchat-phone-real-P3-sheet", sheet: done)
        // The seed's working state again, newer than the idle record.
        let working10 = try DemoSeed.record(kind: .terminalSession, id: 10, json: DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, [
            "title": "Session report", "state_kind": "working", "state_caption": "Working · running tests", "state_tone": "green",
            "target_id": 430, "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-30)),
            "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-194)),
            "report_target_id": 430, "report_done": 1, "report_total": 3, "report_merged": 1
        ]), modifiedAt: Date())
        _ = try await publish("P4 markers", markers: [], session: working10)
        try await workchat("workchat-phone-real-P4")
        return 5
    }
}
