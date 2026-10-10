import Foundation
import WatchtowerKit
import WatchtowerSync

/// The Workbench part of the demo replica (spec §13 B2): three workbenches
/// (one with no sessions and an empty board), sessions in every resolved
/// state, open asks of the three kinds plus closed ones, a board tree with
/// archived targets, and a comment thread plus a resolved root. The Kit mirrors have no public
/// inits, so every record is built as the JSON the hub would publish.
extension DemoSeed {
    static let acmeID: Int64 = 1
    static let websiteID: Int64 = 2
    static let notesID: Int64 = 3

    static func workbenchRecords(now: Date) throws -> [CloudRecord] {
        var records: [CloudRecord] = []
        for (kind, json) in workbenchSlices(now: now) {
            let id = try recordID(json)
            records.append(try record(kind: kind, id: id, json: json, modifiedAt: now))
        }
        return records
    }

    /// Every Workbench slice payload of the demo, in publish order.
    static func workbenchSlices(now: Date) -> [(SliceKind, [String: Any])] {
        let ago: (TimeInterval) -> Date = { now.addingTimeInterval(-$0) }
        let workbenches: [[String: Any]] = [
            JSON.workbench(acmeID, [
                "name": "Acme", "folder_display": "~/Projects/acme", "branch": "main", "changes": 3,
                "open_asks": 3, "open_targets": 7, "in_progress_targets": 3, "blocked_targets": 1, "done_targets": 1,
                "session_counts": JSON.counts(working: 1, waiting: 1, needsApproval: 1, finished: 2, failed: 1, stopped: 1, notRunning: 1),
                "last_session_activity": JSON.stamp(ago(30))
            ]),
            JSON.workbench(websiteID, [
                "name": "Acme Website", "folder_display": "~/Projects/acme-web", "branch": "feature/landing",
                "open_targets": 1, "in_progress_targets": 1, "done_targets": 1,
                "session_counts": JSON.counts(working: 1, stopped: 1),
                "last_session_activity": JSON.stamp(ago(600))
            ]),
            JSON.workbench(notesID, ["name": "Notes", "folder_display": "~/Projects/notes", "branch": "main"])
        ]
        return workbenches.map { (.workbench, $0) }
            + demoSessions(ago).map { (.terminalSession, $0) }
            + demoAsks(ago).map { (.ownerAsk, $0) }
            + demoTargets(ago).map { (.workbenchTarget, $0) }
            + demoComments(ago).map { (.workbenchComment, $0) }
    }

    private static func demoSessions(_ ago: (TimeInterval) -> Date) -> [[String: Any]] {
        let acme: [[String: Any]] = [
            JSON.session(10, workbench: acmeID, [
                "title": "Session report", "state_kind": "working", "state_caption": "Working · running tests",
                "state_tone": "green", "target_id": 430, "last_active_at": JSON.stamp(ago(30)),
                "report_target_id": 430, "report_done": 1, "report_total": 3
            ]),
            JSON.session(11, workbench: acmeID, [
                "title": "Archive closed targets", "created_at": JSON.stamp(ago(4_000)), "state_kind": "waiting_on_ask",
                "state_caption": "Waiting for you · ask #109 · 2 asks", "state_tone": "orange", "state_glyph": "questionmark",
                "open_asks": 2, "oldest_ask_id": 109, "closed_asks": 2, "target_id": 415, "last_active_at": JSON.stamp(ago(120)),
                "report_target_id": 415, "report_done": 1, "report_total": 2, "report_pr_line": "PR #175 open"
            ]),
            JSON.session(12, workbench: acmeID, [
                "title": "Board lanes", "state_kind": "needs_approval", "state_caption": "Needs approval",
                "state_tone": "orange", "state_glyph": "hand.raised.fill", "target_id": 421, "last_active_at": JSON.stamp(ago(300))
            ]),
            JSON.session(13, workbench: acmeID, [
                "title": "Per-lane fold", "state_kind": "finished", "state_caption": "Finished", "state_tone": "blue",
                "state_glyph": "checkmark", "live": false, "is_ring": true, "target_id": 422, "last_active_at": JSON.stamp(ago(7_200)),
                "finish_summary": "Folded done targets per lane."
            ]),
            JSON.session(14, workbench: acmeID, [
                "title": "Ask guard v2", "state_kind": "finished", "state_caption": "Finished · 1 ask open",
                "state_tone": "orange", "state_glyph": "checkmark", "live": false, "is_ring": true, "open_asks": 1,
                "oldest_ask_id": 110, "closed_asks": 1, "target_id": 431, "last_active_at": JSON.stamp(ago(3_600))
            ]),
            JSON.session(15, workbench: acmeID, [
                "title": "Lane totals", "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary",
                "state_glyph": "pause.fill", "live": false, "is_ring": true, "last_active_at": JSON.stamp(ago(10_800))
            ]),
            JSON.session(16, workbench: acmeID, [
                "title": "Undo archive", "state_kind": "failed", "state_caption": "Error: rate limit", "state_tone": "red",
                "state_glyph": "exclamationmark", "live": false, "is_ring": true, "agent_error": "rate_limit",
                "target_id": 416, "last_active_at": JSON.stamp(ago(14_400))
            ]),
            JSON.session(17, workbench: acmeID, [
                "title": "Scratch", "state_kind": "not_started", "state_caption": "Not running", "state_tone": "secondary",
                "live": false, "is_ring": true, "last_active_at": JSON.stamp(ago(86_400))
            ])
        ]
        let website: [[String: Any]] = [
            JSON.session(20, workbench: websiteID, [
                "title": "Landing page", "state_kind": "running", "state_caption": "Running", "state_tone": "green",
                "target_id": 500, "last_active_at": JSON.stamp(ago(600))
            ]),
            JSON.session(21, workbench: websiteID, [
                "title": "Pricing table", "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary",
                "state_glyph": "pause.fill", "live": false, "is_ring": true, "target_id": 501, "last_active_at": JSON.stamp(ago(5_400))
            ])
        ]
        return acme + website
    }

    private static func demoAsks(_ ago: (TimeInterval) -> Date) -> [[String: Any]] {
        [
            JSON.ask(109, workbench: acmeID, [
                "session_id": 11, "target_id": 415, "kind": "question", "title": "Which menu wording?",
                "summary": "The header menu needs one wording for the archive action.", "created_at": JSON.stamp(ago(900)),
                "payload": [
                    "focus": [], "checklist": [],
                    "questions": [[
                        "id": "wording", "question": "Which wording should the menu use?",
                        "options": [
                            ["label": "Archive Closed Targets Now", "recommended": true],
                            ["label": "Archive Now"]
                        ]
                    ]]
                ],
                "quick": [
                    "question_id": "wording",
                    "options": [["label": "Archive Closed Targets Now", "recommended": true], ["label": "Archive Now", "recommended": false]]
                ]
            ]),
            // The second round of #107 (superseded), its snapshot cut by the hub.
            JSON.ask(110, workbench: acmeID, [
                "session_id": 14, "target_id": 431, "kind": "review", "title": "Review the ask guard plan",
                "summary": "The plan for the second ask guard prompt.", "created_at": JSON.stamp(ago(3_600)),
                "previous_ask_id": 107, "changes": "Step 2 now names the Stop hook.",
                "payload": ["focus": [["text": "Is the stop blocked early enough?", "heading": "Steps"]]],
                "doc_path": "docs/plans/ask-guard-v2.md",
                "doc_snapshot": "# Ask guard v2\n\n## Steps\n\nStep 1: block the stop.\n\nStep 2: the Stop hook asks the owner first.\n",
                "doc_clipped": true, "doc_bytes": 412_000
            ]),
            JSON.ask(111, workbench: acmeID, [
                "session_id": 11, "target_id": 415, "kind": "check", "title": "Check the archive menu",
                "summary": "Open the header menu and archive the closed targets.", "created_at": JSON.stamp(ago(300)),
                "payload": ["checklist": [
                    ["id": "1", "text": "Open the header menu"],
                    ["id": "2", "text": "Choose Archive Closed Targets Now", "hint": "The closed targets leave the board"]
                ]]
            ]),
            JSON.ask(105, workbench: acmeID, [
                "session_id": 11, "target_id": 415, "kind": "question", "status": "delivered", "title": "Keep the counter?",
                "created_at": JSON.stamp(ago(86_400)), "answered_at": JSON.stamp(ago(80_000)), "delivered_at": JSON.stamp(ago(79_000)),
                "payload": ["questions": [[
                    "id": "counter", "question": "Keep the archived counter?", "options": [["label": "Keep it"], ["label": "Drop it"]]
                ]]],
                "answer": [
                    "verdict": "", "answers": [["id": "counter", "labels": ["Drop it"], "other": ""]],
                    "checklist": [Any](), "comments": [Any](), "note": "Not needed on the board."
                ]
            ]),
            JSON.ask(106, workbench: acmeID, [
                "session_id": 11, "kind": "check", "status": "answered", "title": "Check the undo",
                "created_at": JSON.stamp(ago(40_000)), "answered_at": JSON.stamp(ago(30_000))
            ]),
            JSON.ask(107, workbench: acmeID, [
                "session_id": 14, "target_id": 431, "kind": "review", "status": "withdrawn", "withdrawn_reason": "superseded",
                "title": "Review the ask guard plan", "created_at": JSON.stamp(ago(20_000))
            ])
        ]
    }

    private static func demoTargets(_ ago: (TimeInterval) -> Date) -> [[String: Any]] {
        let acme: [[String: Any]] = [
            JSON.target(400, workbench: acmeID, ["text": "Board archive", "status": "in_progress", "children_count": 3, "progress": 0.5]),
            JSON.target(415, workbench: acmeID, [
                "parent_id": 400, "text": "Archive Closed Targets Now", "status": "in_progress", "priority": "high",
                "progress": 0.5, "pr": "175", "branch": "feature/archive-now", "open_asks": 2, "open_comments": 1,
                "session_ids": [11], "intent": "Archive closed targets on demand from the header menu."
            ]),
            JSON.target(416, workbench: acmeID, ["parent_id": 400, "text": "Undo Archive Now", "session_ids": [16]]),
            JSON.target(417, workbench: acmeID, [
                "parent_id": 400, "text": "Archive view", "status": "done", "archived": true, "progress": 1,
                "last_status_at": JSON.stamp(ago(864_000)), "last_status_actor": "owner"
            ]),
            JSON.target(420, workbench: acmeID, ["text": "Board hierarchy", "children_count": 2, "progress": 0.5]),
            JSON.target(421, workbench: acmeID, [
                "parent_id": 420, "text": "Lane totals", "status": "blocked", "priority": "high", "session_ids": [12, 15]
            ]),
            JSON.target(422, workbench: acmeID, ["parent_id": 420, "text": "Per-lane fold", "status": "done", "progress": 1, "session_ids": [13]]),
            JSON.target(430, workbench: acmeID, ["text": "Session report", "status": "in_progress", "progress": 0.3, "session_ids": [10]]),
            JSON.target(431, workbench: acmeID, ["text": "Ask guard v2", "priority": "low", "open_asks": 1, "session_ids": [14]]),
            JSON.target(390, workbench: acmeID, ["text": "Old onboarding", "status": "done", "archived": true, "progress": 1]),
            JSON.target(391, workbench: acmeID, ["text": "Legacy inbox", "status": "dismissed", "archived": true])
        ]
        let website: [[String: Any]] = [
            JSON.target(500, workbench: websiteID, ["text": "Landing page", "status": "in_progress", "progress": 0.6, "session_ids": [20]]),
            JSON.target(501, workbench: websiteID, ["text": "Pricing table", "status": "done", "progress": 1, "session_ids": [21]])
        ]
        return (acme + website).map { target in
            var target = target
            target["created_at"] = target["created_at"] ?? JSON.stamp(ago(172_800))
            target["updated_at"] = target["updated_at"] ?? JSON.stamp(ago(3_600))
            return target
        }
    }

    private static func demoComments(_ ago: (TimeInterval) -> Date) -> [[String: Any]] {
        [
            JSON.comment(80, workbench: acmeID, target: 415, [
                "author": "agent", "agent_label": "claude", "body": "The plan is on the board. One question on the menu wording.",
                "created_at": JSON.stamp(ago(1_800))
            ]),
            JSON.comment(81, workbench: acmeID, target: 415, [
                "parent_id": 80, "author": "owner", "body": "Answered in the ask.", "read": true, "created_at": JSON.stamp(ago(1_200))
            ]),
            JSON.comment(82, workbench: acmeID, target: 421, [
                "author": "agent", "agent_label": "claude", "body": "Blocked on the lane layout; resolved for now.",
                "status": "resolved", "read": true, "created_at": JSON.stamp(ago(7_200))
            ])
        ]
    }

    /// One DataZone record carrying `json` as its payload.
    static func record(kind: SliceKind, id: Int64, json: [String: Any], modifiedAt: Date) throws -> CloudRecord {
        let payload = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return CloudRecordFactory.record(for: SliceRecord(kind: kind, id: String(id), modifiedAt: modifiedAt, payload: payload))
    }

    private static func recordID(_ json: [String: Any]) throws -> Int64 {
        guard let id = json["id"] as? Int64 else { throw DemoSeedError.missingID }
        return id
    }

    enum DemoSeedError: Error {
        case missingID
        case recordingNotRegistered
    }

    /// Payload builders: every required key with a neutral default, then the
    /// caller's overrides. Dates are Unix seconds (RelayCoder JSON).
    enum JSON {
        static func stamp(_ date: Date) -> Int {
            Int(date.timeIntervalSince1970)
        }

        static func counts(
            working: Int = 0,
            waiting: Int = 0,
            needsApproval: Int = 0,
            finished: Int = 0,
            failed: Int = 0,
            stopped: Int = 0,
            notRunning: Int = 0
        ) -> [String: Int] {
            [
                "working": working, "waiting": waiting, "needs_approval": needsApproval, "finished": finished,
                "failed": failed, "stopped": stopped, "not_running": notRunning
            ]
        }

        static func workbench(_ id: Int64, _ overrides: [String: Any] = [:]) -> [String: Any] {
            merge([
                "id": id, "name": "Acme", "description": "", "folder_display": "~/Projects/acme", "branch": "main",
                "detached": false, "changes": 0, "open_asks": 0, "open_targets": 0, "in_progress_targets": 0,
                "blocked_targets": 0, "done_targets": 0, "session_counts": counts(), "archive_after_days": 14
            ], overrides)
        }

        static func session(_ id: Int64, workbench: Int64, _ overrides: [String: Any] = [:]) -> [String: Any] {
            let stamp = stamp(Date())
            return merge([
                "id": id, "workbench_id": workbench, "title": "Session \(id)", "agent": "claude_code",
                "created_at": stamp, "last_active_at": stamp, "live": true, "state_kind": "running",
                "state_caption": "Running", "state_tone": "green", "state_glyph": "", "is_ring": false,
                "open_asks": 0, "closed_asks": 0, "finish_summary": "", "agent_error": ""
            ], overrides)
        }

        static func target(_ id: Int64, workbench: Int64, _ overrides: [String: Any] = [:]) -> [String: Any] {
            let stamp = stamp(Date())
            return merge([
                "id": id, "workbench_id": workbench, "text": "Target \(id)", "intent": "", "status": "todo",
                "priority": "medium", "progress": 0, "branch": "", "pr": "", "archived": false, "children_count": 0,
                "open_comments": 0, "unread_for_owner": 0, "open_asks": 0, "session_ids": [Int64](),
                "work_on_prompt": "Work on target #\(id).", "created_at": stamp, "updated_at": stamp
            ], overrides)
        }

        static func ask(_ id: Int64, workbench: Int64, _ overrides: [String: Any] = [:]) -> [String: Any] {
            merge([
                "id": id, "workbench_id": workbench, "workbench_name": "Acme", "kind": "question", "status": "open",
                "created_at": stamp(Date()), "title": "Ask \(id)", "summary": "", "changes": "", "doc_path": ""
            ], overrides)
        }

        static func comment(_ id: Int64, workbench: Int64, target: Int64, _ overrides: [String: Any] = [:]) -> [String: Any] {
            merge([
                "id": id, "workbench_id": workbench, "target_id": target, "author": "agent", "agent_label": "",
                "body": "", "status": "open", "created_at": stamp(Date()), "read": false
            ], overrides)
        }

        private static func merge(_ base: [String: Any], _ overrides: [String: Any]) -> [String: Any] {
            base.merging(overrides) { _, new in new }
        }
    }
}
