import Foundation
import WatchtowerSync

/// The session-detail part of the demo replica (spec §13 B3): session
/// reports for the working, waiting and finished Acme sessions, and
/// timelines for those plus the needs-approval and failed ones. The
/// not-started "Scratch" session has neither, as a fresh session would.
extension DemoSeed {
    static func sessionDetailRecords(now: Date) throws -> [CloudRecord] {
        try sessionDetailSlices(now: now).map { kind, id, json in
            try record(kind: kind, id: id, json: json, modifiedAt: now)
        }
    }

    /// `(kind, session id, payload)` per record. A report carries Go's UTC
    /// datetime strings; a timeline Unix seconds, as the hub writes them.
    static func sessionDetailSlices(now: Date) -> [(SliceKind, Int64, [String: Any])] {
        let ago: (TimeInterval) -> Int = { JSON.stamp(now.addingTimeInterval(-$0)) }
        let reports: [(Int64, [String: Any])] = [
            (10, report(10, title: "Session report", [
                "progress": ["done": 1, "total": 3],
                "now": [["id": 430, "text": "Session report", "status": "in_progress", "branch": ""]],
                "next": [["id": 432, "text": "Report on the phone", "status": "todo"]]
            ])),
            (11, report(11, title: "Archive closed targets", [
                "progress": ["done": 2, "total": 5],
                "on_you": [
                    ["id": 109, "kind": "question", "title": "Which menu wording?", "target_id": 415],
                    ["id": 111, "kind": "check", "title": "Check the archive menu", "target_id": 415]
                ],
                "now": [[
                    "id": 415, "text": "Archive Closed Targets Now", "status": "in_progress", "branch": "feature/archive-now"
                ]],
                "next": [["id": 416, "text": "Undo Archive Now", "status": "todo"]],
                "phases": [[
                    "target_id": 400, "text": "Board archive", "done": 1, "total": 3,
                    "items": [
                        ["id": 417, "text": "Archive view", "status": "done"],
                        ["id": 415, "text": "Archive Closed Targets Now", "status": "in_progress"],
                        ["id": 416, "text": "Undo Archive Now", "status": "todo"]
                    ]
                ]],
                "prs": [[
                    "ref": "pr:175", "pr_number": 175, "title": "Archive closed targets now", "state": "open", "targets": [415]
                ]]
            ])),
            (13, report(13, title: "Per-lane fold", [
                "progress": ["done": 1, "total": 1],
                "prs": [["ref": "branch:feature/lane-fold", "state": "unknown", "targets": [422]]]
            ]))
        ]
        let timelines: [(Int64, [[String: Any]])] = [
            (10, [
                milestone(ago(30), "state", "Working · running tests"),
                milestone(ago(1_200), "target_linked", "Linked #430 Session report", ref: 430),
                milestone(ago(1_500), "state", "Started")
            ]),
            (11, [
                milestone(ago(300), "ask_opened", "Asked you · ask #111", ref: 111),
                milestone(ago(900), "ask_opened", "Asked you · ask #109", ref: 109),
                milestone(ago(1_500), "pr", "PR #175 open"),
                milestone(ago(2_400), "target_status", "#415 todo → in progress · agent", ref: 415),
                milestone(ago(3_000), "target_linked", "Linked #415 Archive Closed Targets Now", ref: 415),
                milestone(ago(4_000), "state", "Started")
            ]),
            (12, [
                milestone(ago(300), "state", "Needs approval"),
                milestone(ago(900), "state", "Started")
            ]),
            (13, [
                milestone(ago(7_200), "finished", "Finished · Folded done targets per lane."),
                milestone(ago(9_000), "phase", "Board hierarchy started", ref: 420),
                milestone(ago(10_000), "state", "Started")
            ]),
            (16, [
                milestone(ago(14_400), "state", "Error: rate limit"),
                milestone(ago(15_000), "state", "Started")
            ])
        ]
        return reports.map { (.sessionReport, $0.0, $0.1) }
            + timelines.map { id, milestones in
                (.sessionTimeline, id, ["session_id": id, "milestones": milestones])
            }
    }

    private static func report(_ id: Int64, title: String, _ fields: [String: Any]) -> [String: Any] {
        var report: [String: Any] = [
            "session": ["id": id, "title": title, "kind": "claude"],
            "progress": ["done": 0, "total": 0],
            "on_you": [], "now": [], "next": [], "phases": [], "prs": [], "pr_note": ""
        ]
        report.merge(fields) { _, new in new }
        return report
    }

    private static func milestone(_ at: Int, _ kind: String, _ text: String, ref: Int64? = nil) -> [String: Any] {
        var milestone: [String: Any] = ["at": at, "kind": kind, "text": text]
        milestone["ref"] = ref
        return milestone
    }
}
