import Foundation
import WatchtowerInterface
import WatchtowerKit
import WatchtowerSync

// MARK: - The phone Inbox (mobile Inbox spec §7, mockups §1–§6)

extension DemoSeed {
    /// The demo hub's Inbox as the hub publishes it (`inbox_folder` and `inbox_card` records, the generated
    /// `Folder` and `Card` JSON): the root with Waiting for me (three rows wait), the legacy entries (Morning
    /// brief, Track my threads, Idea finder) and an automation's card; Needs approval with two proposals waiting,
    /// a failed one and a reminder; the owner's folders (Release acme 2.0 with QA under it, Blockers, Team); an
    /// artifact with every block kind across two cards, and one this build cannot read. Neutral samples only.
    enum Inbox {
        static let rootID: Int64 = 1
        static let approvalsID: Int64 = 2
        static let releaseID: Int64 = 3
        static let blockersID: Int64 = 4
        static let teamID: Int64 = 5
        static let qaID: Int64 = 6
        static let reportsID: Int64 = 7

        static let waitingForMe = "o201"
        static let roundup = "o205"
        static let checklist = "o206"
        static let sprintBoard = "o209"
        static let brief = "brief-today"
        static let tracks = "tracks"
        static let ideas = "ideas"
        static let slackProposal = "a101"
        static let replyProposal = "a102"
        static let weeklyReport = "o901"

        /// The heartbeat's capabilities on a hub that publishes the Inbox (and chat).
        static let capabilities = HeartbeatCapabilities(chat: "on", inbox: "on")

        static func feed(now: Date) -> Feed {
            Feed(v: 1, builtAt: stamp(now), folders: folders(), cards: cards(now: now))
        }

        /// The hub's records of `feed(now:)`.
        static func records(now: Date) throws -> [CloudRecord] {
            let encoder = JSONEncoder()
            let cards = cards(now: now)
            // Each folder with its cards' ids in the feed's order, as the hub publishes it; the cards order-free.
            let folders = try folders().map { folder in
                var object = try JSONSerialization.jsonObject(with: try encoder.encode(folder)) as? [String: Any] ?? [:]
                object["card_ids"] = cards.filter { $0.folderID == folder.id }.map(\.id)
                let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                return CloudRecordFactory.record(for: SliceRecord(kind: .inboxFolder, id: String(folder.id), modifiedAt: now, payload: payload))
            }
            let cardRecords = try cards.map { card in
                CloudRecordFactory.record(for: SliceRecord(kind: .inboxCard, id: card.id, modifiedAt: now, payload: try encoder.encode(card)))
            }
            return folders + cardRecords
        }

        static func folders() -> [Folder] {
            [
                folder(rootID, .root, "Inbox", parent: nil, position: 0, count: 5, waiting: 3),
                folder(approvalsID, .approvals, "Needs approval", parent: rootID, position: 0, count: 4, waiting: 2),
                folder(releaseID, .owner, "Release acme 2.0", icon: "flag", parent: rootID, position: 1, count: 2),
                folder(blockersID, .owner, "Blockers", icon: "shippingbox", parent: rootID, position: 2, count: 1),
                folder(teamID, .owner, "Team", icon: "person.2", parent: rootID, position: 3, count: 0),
                folder(qaID, .owner, "QA", icon: "testtube.2", parent: releaseID, position: 0, count: 0)
            ]
        }

        static func cards(now: Date) -> [InboxCard] {
            rootCards(now: now) + approvalCards(now: now) + folderCards(now: now)
        }

        // MARK: The root

        static func rootCards(now: Date) -> [InboxCard] {
            [
                card(
                    waitingForMe, rootID, .artifact, "Waiting for me", source: "Waiting for me", at: now.addingTimeInterval(-360),
                    living: true, unread: true, pinned: true, blocks: waitingBlocks, refs: waitingRefs
                ),
                legacyBrief(now: now),
                card(
                    tracks, rootID, .legacy, "Track my threads", source: InboxText.withNews(2), at: now.addingTimeInterval(-4_200),
                    blocks: tracksBlocks, refs: [501, 502, 503].map { ref(.track, $0, waits: false) },
                    legacy: LegacySection(kind: .tracks, items: [], attention: [])
                ),
                card(
                    ideas, rootID, .legacy, "Idea finder", source: InboxText.toJudge(1), at: now.addingTimeInterval(-4_800),
                    blocks: ideasBlocks,
                    refs: [
                        ref(.idea, 601, waits: true, ideaKind: "idea", ideaStatus: "proposed"),
                        ref(.idea, 602, waits: false, ideaKind: "idea", ideaStatus: "active"),
                        ref(.idea, 603, waits: false, ideaKind: "decision", ideaStatus: "active")
                    ],
                    legacy: LegacySection(kind: .ideas, items: [], attention: [])
                ),
                card(
                    roundup, rootID, .artifact, "Weekly mail roundup", source: "Weekly mail roundup", at: now.addingTimeInterval(-7_200),
                    unread: true, automation: CardAutomation(id: 12, name: "Weekly mail roundup", builtinID: "", runID: 12),
                    blocks: roundupBlocks, preview: "Three threads need an answer",
                    actions: [
                        CardAction(index: 0, kind: "reply", label: "Draft replies", state: .enabled, detail: "ready", note: "", until: ""),
                        CardAction(index: 1, kind: "target", label: "＋ Task", state: .enabled, detail: "idle", note: "", until: ""),
                        CardAction(index: 2, kind: "chat", label: "Chat", state: .macOnly, detail: "", note: "", until: "")
                    ]
                )
            ]
        }

        /// One Waiting for me row (mockup §2): who · where, the text, the age (warning past 24 h), its trigger.
        struct WaitingRow {
            let id: Int64
            let who: String
            let text: String
            let age: String
            let tone: String
            let trigger: String
        }

        static let waitingRows = [
            WaitingRow(
                id: 301, who: "Colleague A · #acme-release", text: "Can you sign off the 2.0 checklist before 15:00? QA is done on our side.",
                age: "26 h", tone: "warning", trigger: "slack_mention"),
            WaitingRow(
                id: 302, who: "Colleague B · DM", text: "Quick one: are we keeping the old login page after 2.0?", age: "5 h", tone: "neutral",
                trigger: "slack_dm"),
            WaitingRow(
                id: 303, who: "ACME-412 · Jira · mentioned you", text: "@owner which build fixed the login loop?", age: "3 h", tone: "neutral",
                trigger: "jira_mention"),
            WaitingRow(
                id: 304, who: "partner@example.com · mail", text: "Contract renewal — need your answer this week", age: "1 h", tone: "neutral",
                trigger: "email_received")
        ]

        static var waitingBlocks: [[String: Any]] {
            [list(rows: waitingRows.map { row in
                ["title": row.text, "subtitle": row.who, "badge": ["text": row.age, "tone": row.tone], "link": "", "actions": [],
                 "ref": ["kind": "inbox_item", "id": row.id]]
            })]
        }

        static var waitingRefs: [RefFacts] {
            waitingRows.map { row in
                ref(.inboxItem, row.id, waits: row.id != 304, reply: row.id != 304, link: "https://example.com/acme/thread/\(row.id)",
                    trigger: row.trigger)
            }
        }

        /// One Morning brief plan item.
        struct PlanRow {
            let id: Int64
            let title: String
            let note: String
            let start: Date
            let done: Bool
        }

        static func legacyBrief(now: Date) -> InboxCard {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: now)
            let at = { (hour: Int, minute: Int) in day.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60)) }
            let plan = [
                PlanRow(id: 401, title: "Review ACME-412 fix", note: "", start: at(9, 0), done: true),
                PlanRow(id: 402, title: "Standup", note: "", start: at(9, 30), done: true),
                PlanRow(id: 403, title: "Sign off the 2.0 checklist", note: "from Waiting for me", start: at(11, 0), done: false),
                PlanRow(id: 404, title: "1:1 with colleague B", note: "calendar", start: at(14, 0), done: false)
            ]
            let items = plan.map {
                LegacyItem(
                    refKind: .planItem, id: $0.id, title: $0.title, subtitle: $0.note, preview: "", stamp: stamp($0.start), end: "",
                    unread: false, high: false, stopped: false, done: $0.done, date: ""
                )
            }
            let rows: [[String: Any]] = plan.map { item in
                var row: [String: Any] = ["title": (item.done ? "✓ " : "") + item.title, "link": "", "actions": [],
                                          "ref": ["kind": "plan_item", "id": item.id]]
                if !item.note.isEmpty { row["subtitle"] = item.note }
                if item.done { row["tone"] = "success" }
                return row
            }
            let blocks: [[String: Any]] = [
                ["type": "heading", "text": "Plan · 2 of 4", "level": 2],
                list(rows: rows, empty: "Nothing planned"),
                ["type": "heading", "text": "Attention", "level": 2],
                ["type": "text", "markdown": "Release 2.0 tag waits on your sign-off; the docs link is the only red item."]
            ]
            return card(
                brief, rootID, .legacy, InboxText.legacyBriefTitle, source: "Plan: 2 of 4 done", at: at(8, 2), unread: true,
                blocks: blocks, refs: plan.map { ref(.planItem, $0.id, waits: false) },
                legacy: LegacySection(kind: .morningBrief, items: items, attention: [])
            )
        }

        static var tracksBlocks: [[String: Any]] {
            [
                list(rows: [
                    ["title": "Budget approval for Q1", "subtitle": "Finance asked for the revised numbers by Friday.",
                     "badge": ["text": "2 new", "tone": "info"], "tone": "info", "link": "", "actions": [], "ref": ["kind": "track", "id": 501]],
                    ["title": "Hiring: backend role", "subtitle": "Second-round slot moved to Thursday.",
                     "badge": ["text": "1 new", "tone": "info"], "tone": "info", "link": "", "actions": [], "ref": ["kind": "track", "id": 502]],
                    ["title": "Office move", "subtitle": "Track", "link": "", "actions": [], "ref": ["kind": "track", "id": 503]]
                ], empty: "No tracks"),
                list(title: InboxText.stopped(3), rows: [
                    ["title": "Vendor renewal", "link": "", "actions": []],
                    ["title": "Old CI runners", "link": "", "actions": []],
                    ["title": "Team offsite", "link": "", "actions": []]
                ], empty: "")
            ]
        }

        static var ideasBlocks: [[String: Any]] {
            [
                list(title: InboxText.toJudgeHeader(1), rows: [
                    ["title": "Self-serve release notes page", "subtitle": "Idea · proposed · from #acme-release", "tone": "warning",
                     "link": "", "actions": [], "ref": ["kind": "idea", "id": 601]]
                ], empty: ""),
                list(title: InboxText.recent, rows: [
                    ["title": "Shared on-call calendar", "subtitle": "Idea · active", "link": "", "actions": [], "ref": ["kind": "idea", "id": 602]],
                    ["title": "Keep the old login page until 2.1", "subtitle": "Decision", "link": "", "actions": [],
                     "ref": ["kind": "idea", "id": 603]]
                ], empty: "")
            ]
        }

        /// Mockup §4's feed card: a heading, metrics, a toned list and an actions block (Chat stays on the hub's
        /// computer); the card's `actions` are the block's buttons, by their press address.
        static var roundupBlocks: [[String: Any]] {
            [
                ["type": "heading", "text": "Three threads need an answer", "level": 1],
                ["type": "metrics", "items": [
                    ["label": "to answer", "value": "3", "hint": ""],
                    ["label": "read only", "value": "11", "hint": ""],
                    ["label": "from new people", "value": "2", "hint": ""]
                ]],
                list(rows: [
                    ["title": "Contract renewal", "subtitle": "partner@example.com · Tue", "badge": ["text": "due Fri", "tone": "danger"],
                     "link": "", "actions": []],
                    ["title": "Invoice 2026-11 question", "subtitle": "billing@example.com · Mon",
                     "badge": ["text": "this week", "tone": "warning"], "link": "", "actions": []],
                    ["title": "Conference talk slot", "subtitle": "events@example.com · Mon", "badge": ["text": "FYI", "tone": "info"],
                     "link": "", "actions": []]
                ]),
                ["type": "actions", "actions": [
                    ["label": "Draft replies", "kind": "reply", "reply": "draft"],
                    ["label": "＋ Task", "kind": "target", "target": ["title": "Answer the contract renewal"]],
                    ["label": "Chat", "kind": "chat", "chat": "Help me answer these threads"]
                ]]
            ]
        }

        // MARK: Needs approval

        static func approvalCards(now: Date) -> [InboxCard] {
            let day = Calendar.current.startOfDay(for: now)
            return [
                card(
                    slackProposal, approvalsID, .approvalNative, "Send a Slack message", source: "to #acme-release · ϟ Release notes · run #4",
                    at: now.addingTimeInterval(-1_800), hash: "args-101",
                    approval: approval("slack_send_message", "Send a Slack message", "Release 2.0 is tagged; checklist in the thread.", "args-101")
                ),
                card(
                    replyProposal, approvalsID, .approvalNative, "Reply in #acme-release",
                    source: "Reply from Waiting for me · \(InboxText.thisIPhone)", at: now.addingTimeInterval(-900), hash: "args-102",
                    approval: approval(
                        "slack_send_message", "Reply in #acme-release", "Signing off now — docs link is the only open item…", "args-102")
                ),
                card(
                    "a103", approvalsID, .approvalNative, "Create a Linear issue", source: "ϟ Triage", at: now.addingTimeInterval(-5_400),
                    hash: "args-103",
                    approval: approval(
                        "linear_create_issue", "Create a Linear issue", "Checklist link broken on the release page", "args-103",
                        status: "failed", error: "the team was archived")
                ),
                card(
                    "r104", approvalsID, .reminder, "Answer colleague A about the budget", source: "Reminder", at: day.addingTimeInterval(14 * 3_600),
                    preview: "Answer colleague A about the budget", link: "https://example.com/acme/thread/budget",
                    refs: [ref(.reminder, 104, waits: true)]
                )
            ]
        }

        static func approval(
            _ tool: String, _ title: String, _ summary: String, _ sha: String, status: String = "pending", error: String = ""
        ) -> Approval {
            Approval(
                tool: tool, title: title, summary: summary, argsSHA256: sha, status: status, error: error, proposer: "assistant",
                reason: "", editOnMac: false, target: "", targetNote: "", targetUntil: "", superseded: false, disclosure: "",
                recipeText: "", diff: [], recipeClipped: false
            )
        }

        // MARK: The owner's folders

        static func folderCards(now: Date) -> [InboxCard] {
            [
                card(
                    checklist, releaseID, .artifact, "Release checklist", source: "Release checklist", at: now.addingTimeInterval(-720),
                    living: true, unread: true, automation: CardAutomation(id: 7, name: "Release checklist", builtinID: "", runID: 31),
                    blocks: checklistBlocks, preview: "4 of 9 items green · 2 blockers"
                ),
                card(
                    "o207", releaseID, .artifact, "Changelog draft", source: "Changelog draft", at: now.addingTimeInterval(-3_000), unread: true,
                    automation: CardAutomation(id: 8, name: "Changelog draft", builtinID: "", runID: 4),
                    preview: "Twelve merged changes since 1.9; three need a note from the owner…",
                    body: "Twelve merged changes since 1.9; three need a note from the owner before the tag."
                ),
                card(
                    sprintBoard, blockersID, .artifact, "Sprint board", source: "Sprint board", at: now.addingTimeInterval(-180), living: true,
                    automation: CardAutomation(id: 9, name: "Sprint board", builtinID: "", runID: 88),
                    rawBlocks: #"{"blocks":[],"v":2}"#,
                    preview: "Sprint 47: 18 of 24 done.",
                    body: "Sprint 47: 18 of 24 done. Blocked: ACME-401 (waiting on design), ACME-415 (needs review)…"
                )
            ]
        }

        static let checklistColumns: [[String: Any]] = ["Item", "Owner", "State", "Since"].map { ["title": $0, "align": "leading"] }

        static let checklistRows: [[Any]] = [
            ["QA pass", "Colleague C", ["text": "green", "tone": "success"], "Mon"],
            ["Docs link", "Colleague C", ["text": "red", "tone": "danger"], "Tue"],
            ["Changelog", "You", ["text": "draft", "tone": "warning"], "Wed"]
        ]

        /// Mockup §4's living card: a heading, a short text, a four-column table (it scrolls), a person and a link.
        static var checklistBlocks: [[String: Any]] {
            [
                ["type": "heading", "text": "acme 2.0 — 4 of 9 green", "level": 1],
                ["type": "text", "markdown": "Two blockers left before the **2.0** tag."],
                ["type": "table", "title": "", "columns": checklistColumns, "rows": checklistRows],
                ["type": "person", "name": "Colleague C", "role": "QA lead", "lines": ["fixing the docs link"], "link": ""],
                ["type": "link", "title": "Release page", "url": "https://example.com/acme/releases/2.0", "subtitle": "example.com"]
            ]
        }

        /// A folder of reports for mockup §6's Didn't confirm and Older cards frames: `more` cards left on the hub.
        static func reportsFeed(now: Date, more: Int) -> Feed {
            let reports = folder(reportsID, .owner, "Reports", icon: "doc.text", parent: rootID, position: 4, count: 2)
            let monday = Calendar.current.date(byAdding: .day, value: -2, to: now) ?? now
            let cards = [
                card(
                    weeklyReport, reportsID, .artifact, "Weekly report for acme", source: "Report digest", at: monday,
                    automation: CardAutomation(id: 21, name: "Weekly report", builtinID: "", runID: 9), body: "Weekly report"
                ),
                card(
                    "o902", reportsID, .artifact, "Budget review", source: "Report digest", at: monday.addingTimeInterval(-11 * 86_400),
                    body: "Budget review"
                )
            ]
            return Feed(
                v: 1, builtAt: stamp(now), folders: [folders()[0], reports], cards: cards,
                more: more > 0 ? [FolderMore(folderID: reportsID, count: more)] : nil
            )
        }

        // MARK: Builders

        static func stamp(_ date: Date) -> String {
            date.ISO8601Format()
        }

        static func folder(
            _ id: Int64, _ kind: FolderKind, _ title: String, icon: String = "", parent: Int64?, position: Int, count: Int, waiting: Int = 0
        ) -> Folder {
            Folder(
                id: id, kind: kind, slug: title.lowercased(), title: title, icon: icon, parentID: parent, position: position, hidden: false,
                count: count, waiting: waiting
            )
        }

        static func ref(
            _ kind: RefKind,
            _ id: Int64,
            waits: Bool,
            reply: Bool = false,
            link: String = "",
            trigger: String = "",
            ideaKind: String = "",
            ideaStatus: String = ""
        ) -> RefFacts {
            RefFacts(
                kind: kind, id: id, open: true, waits: waits, reply: reply, replyWaiting: false, link: link, triggerType: trigger,
                custom: false, linkedTargetID: 0, ideaKind: ideaKind, ideaStatus: ideaStatus
            )
        }

        static func list(title: String = "", rows: [[String: Any]], empty: String = "Nothing here") -> [String: Any] {
            ["type": "list", "title": title, "empty": empty, "rows": rows]
        }

        static func document(_ blocks: [[String: Any]]) -> String {
            guard !blocks.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: ["v": 1, "blocks": blocks], options: [.sortedKeys]) else { return "" }
            return String(bytes: data, encoding: .utf8) ?? ""
        }

        static func card(
            _ id: String,
            _ folder: Int64,
            _ kind: CardKind,
            _ title: String,
            source: String,
            at: Date,
            living: Bool = false,
            unread: Bool = false,
            pinned: Bool = false,
            automation: CardAutomation? = nil,
            blocks: [[String: Any]] = [],
            rawBlocks: String? = nil,
            preview: String = "",
            body: String = "",
            link: String = "",
            hash: String? = nil,
            actions: [CardAction] = [],
            refs: [RefFacts] = [],
            approval: Approval? = nil,
            legacy: LegacySection? = nil
        ) -> InboxCard {
            InboxCard(
                id: id, folderID: folder, cardKind: kind, title: title, sourceLine: source, preview: preview, stamp: stamp(at), living: living,
                unread: unread, priority: "medium", pinned: pinned, automation: automation, blocks: rawBlocks ?? document(blocks), body: body,
                bodyClipped: false, link: link, contentHash: hash ?? "hash-\(id)", actions: actions, refFacts: refs, approval: approval,
                legacy: legacy
            )
        }
    }
}
