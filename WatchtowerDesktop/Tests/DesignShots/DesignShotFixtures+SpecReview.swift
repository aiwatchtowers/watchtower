import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The spec review screen's shots (spec 2026-10-25 §7, mockup
/// `docs/design/mockups/spec-review/flow.html`): Meaning, Chapters and
/// Wrap-up over one finished review of the `acme` workbench's spec, the
/// running reviewer's page, and the classic view's banner. Built once and
/// reused for light and dark.
@MainActor
enum SpecReviewShotFixtures {
    private static var built: [String: (model: SpecReviewModel, path: String)] = [:]

    static func cleanUp() {
        built.values.forEach { TestDatabase.cleanup(path: $0.path) }
        built = [:]
    }

    private static let sections: [(heading: String, body: String)] = [
        ("# Mute a channel for a day", "The owner can mute a noisy channel for a day without leaving it."),
        ("## Goal", "The owner can mute a channel for a day, and it comes back on its own."),
        ("## Behaviour", "Muting lasts twenty-four hours. A muted channel shows a bell with a slash in the sidebar."),
        ("## Decisions", "Mute state lives in the local database. The sidebar refreshes once a minute."),
        ("## Tests", "A test mutes a channel and checks it is back after a day.")
    ]

    private static var snapshot: String {
        sections.map { "\($0.heading)\n\($0.body)\n\n" }.joined()
    }

    private static func chapters() -> [[String: Any]] {
        var offset = 0
        return sections.enumerated().map { index, section in
            let length = "\(section.heading)\n\(section.body)\n\n".utf8.count
            defer { offset += length }
            let heading = section.heading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return ["key": "ch:\(index)", "heading": heading, "start": offset, "end": offset + length]
        }
    }

    private static func resultJSON() throws -> String {
        func agreement(
            _ key: String,
            _ text: String,
            _ status: String,
            _ chapter: String,
            note: String,
            source: (kind: String, ref: String, quote: String, speaker: String)?,
            anchor: (String, String)?
        ) -> [String: Any] {
            var out: [String: Any] = ["key": key, "text": text, "status": status, "chapter": chapter, "note": note]
            if let source {
                out["source"] = ["kind": source.kind, "ref": source.ref, "quote": source.quote, "speaker": source.speaker]
            }
            if let anchor { out["where"] = ["heading": anchor.0, "quote": anchor.1] }
            return out
        }
        let result: [String: Any] = [
            "summary": "The spec carries the idea. One promise has no task, and the refresh interval was chosen without you.",
            "idea": [
                "owner_quote": "let me mute a noisy channel for a day, and bring it back by itself",
                "goal_quote": "The owner can mute a channel for a day, and it comes back on its own.",
                "verdict": "matches", "note": "Same scope; nothing narrowed.",
                "owner_source": ["kind": "conversation", "ref": "entry:4", "quote": "let me mute", "speaker": "owner"]
            ],
            "agreements": [
                agreement("ag:1", "A mute lasts one day", "as_agreed", "ch:2", note: "Stated in Behaviour.",
                          source: ("ask", "ask:41", "a day is enough", "owner"),
                          anchor: ("Behaviour", "Muting lasts twenty-four hours.")),
                agreement("ag:2", "The channel comes back on its own", "as_agreed", "ch:1", note: "",
                          source: ("conversation", "entry:4", "bring it back by itself", "owner"),
                          anchor: ("Goal", "it comes back on its own")),
                agreement("ag:3", "Muted channels look different in the sidebar", "differs", "ch:2",
                          note: "You asked for the channel to be greyed out; the spec draws a bell with a slash.",
                          source: ("conversation", "entry:7", "just grey it out", "owner"),
                          anchor: ("Behaviour", "A muted channel shows a bell with a slash in the sidebar.")),
                agreement("ag:4", "Mentions still notify while muted", "missing", "ch:2",
                          note: "Agreed in the discussion; the spec does not say it.",
                          source: ("conversation", "entry:9", "mentions should still reach me", "owner"), anchor: nil),
                agreement("ag:5", "A test covers the expiry", "as_agreed", "ch:4", note: "",
                          source: ("decisions", "", "", "agent"),
                          anchor: ("Tests", "checks it is back after a day"))
            ],
            "decided_alone": [
                ["key": "da:1", "text": "The sidebar refreshes once a minute", "chapter": "ch:3",
                 "note": "Nobody asked for a minute; a mute ending is then up to a minute late.",
                 "where": ["heading": "Decisions", "quote": "The sidebar refreshes once a minute."]],
                ["key": "da:2", "text": "Mute state lives in the local database", "chapter": "ch:3", "note": "Fits the app.",
                 "where": ["heading": "Decisions", "quote": "Mute state lives in the local database."]]
            ],
            "blind_spots": [
                ["key": "bs:1", "text": "Threads of a muted channel", "chapter": "ch:2",
                 "why": "A reply in a thread you follow would stay silent for a day.",
                 "evidence": ["path": "internal/notify/mute.go", "line": 42]]
            ],
            "checks": [
                ["key": "ck:1", "chapter": "ch:2", "lens": "promises", "question": "Does every promise have a task?",
                 "answer": "concern", "note": "Mentions while muted have none."],
                ["key": "ck:2", "chapter": "ch:2", "lens": "done", "question": "Is there a done criterion?",
                 "answer": "ok", "note": ""],
                ["key": "ck:3", "chapter": "ch:4", "lens": "tests", "question": "Is the expiry tested?", "answer": "ok", "note": ""]
            ],
            "resolved": [
                ["comment_quote": "name what happens after a day", "status": "resolved", "note": "Goal now says it comes back."]
            ],
            "chapters": chapters(),
            "notes": ["The conversation was trimmed to its last 200 entries."],
            "code_read": true,
            "dropped": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    /// One model per state, built on its own test database.
    private static func model(_ key: String, status: String, withResult: Bool) throws -> SpecReviewModel {
        if let entry = built[key] { return entry.model }
        let (pool, path) = try TestDatabase.createPool()
        let snapshot = snapshot
        let result = withResult ? try resultJSON() : ""
        let (projectID, askID) = try pool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            let id = try TestDatabase.insertOwnerAsk(db, projectID: project, kind: "review", docPath: "docs/specs/channel-mute.md")
            try db.execute(sql: "UPDATE owner_asks SET doc_snapshot = ?, title = 'Review the channel mute spec' WHERE id = ?",
                           arguments: [snapshot, id])
            try db.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, reason, model, result, queued_at)
                VALUES (?, ?, ?, 'opus', ?, '2026-10-25T10:00:00Z')
                """, arguments: [id, status, status == "failed" ? "the reviewer ran out of time after 10 minutes" : "", result])
            return (project, id)
        }
        let defaults = UserDefaults(suiteName: DesignShotFixtures.defaultsSuite) ?? .standard
        let asks = OwnerAsksViewModel(dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil),
                                      defaults: defaults)
        var made: SpecReviewModel?
        let task = Task {
            await asks.load(projectID: projectID)
            guard let ask = asks.openAsks[projectID]?.first(where: { $0.id == askID }) else { return }
            let model = SpecReviewModel(ask: ask, db: DatabaseManager(pool: pool), cli: WorkbenchCLI(runner: FakeCLIRunner()),
                                        asks: asks)
            await model.load()
            if withResult {
                await model.mark("ag:1", .ok)
                await model.mark("ag:2", .ok)
                await model.mark("ag:3", .comment, body: "Grey it out as agreed; the bell is too loud.")
                await model.mark("ch:0", .viewed)
                await model.mark("ch:1", .viewed)
                model.chapterKey = "ch:2"
            }
            made = model
        }
        let deadline = Date().addingTimeInterval(5)
        while made == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        task.cancel()
        guard let made else { throw CocoaError(.featureUnsupported) }
        built[key] = (made, path)
        return made
    }

    private static func view(_ make: () throws -> AnyView) -> AnyView {
        do {
            return try make()
        } catch {
            XCTFail("spec review shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    static func screen(_ phase: ReviewPhase) -> AnyView {
        view {
            let model = try model("done", status: "done", withResult: true)
            model.phase = phase
            return AnyView(SpecReviewView(model: model) {}.background(Color(nsColor: .textBackgroundColor)))
        }
    }

    static func running() -> AnyView {
        view {
            let model = try model("running", status: "running", withResult: false)
            return AnyView(SpecReviewView(model: model) {}.background(Color(nsColor: .textBackgroundColor)))
        }
    }

    /// The classic view's strips: a finished review's banner, a failed one's reason.
    static func strips() -> AnyView {
        view {
            let done = try model("done", status: "done", withResult: true)
            let failed = try model("failed", status: "failed", withResult: false)
            let open: () -> Void = {}
            return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
                SpecReviewStatusView(model: done, style: .strip, onOpenFindings: open)
                SpecReviewStatusView(model: failed, style: .strip)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor)))
        }
    }
}
