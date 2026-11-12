import GRDB
import XCTest
@testable import WatchtowerCore

/// A row's content (spec "The list", phase 1): the time label, the
/// markdown preview and each entry kind's title, preview, meta, pill and
/// unread state.
final class InboxRowContentTests: XCTestCase {
    private static let kyiv: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        return calendar
    }()

    /// Wed 11 Nov 2026, 08:02 in Kyiv (UTC+2).
    private func now() throws -> Date { try date("2026-11-11T06:02:00Z") }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }

    private func inputs(
        _ feed: InboxFeedSnapshot = InboxFeedSnapshot(),
        _ folders: InboxFolderMenuSnapshot = InboxFolderMenuSnapshot(tree: .rootOnly)
    ) throws -> InboxFolderEntries.Inputs {
        InboxFolderEntries.Inputs(feed: feed, folders: folders, now: try now(), calendar: Self.kyiv)
    }

    private func message(
        _ id: Int, who: String, trigger: String = "mention", whereText: String? = nil, snippet: String, at text: String
    ) throws -> HomeFeedInboxRow {
        let item = InboxItem(row: Row(["id": id, "snippet": snippet, "trigger_type": trigger]))
        return HomeFeedInboxRow(item: item, stamp: try date(text), who: who, whereText: whereText)
    }

    private func card(
        _ id: Int64,
        automation: Int64 = 1,
        title: String = "Weekly mail roundup",
        body: String = "",
        changed: String = "2026-11-11T05:00:00Z",
        key: String? = nil,
        blocks: String = ""
    ) throws -> AutomationOutputCard {
        AutomationOutputCard(
            id: id, automationID: automation, automationName: "Weekly", runID: 12, title: title, body: body,
            priority: "", createdAt: try date(changed), blocksJSON: blocks, outputKey: key,
            writtenAt: try date(changed), changedAt: try date(changed))
    }

    // MARK: - Time and preview

    func testTimeLabels() throws {
        let now = try now()
        let cases: [(String, String)] = [
            ("2026-11-11T06:02:00Z", "08:02"),
            ("2026-11-10T18:00:00Z", "yesterday"),
            ("2026-11-09T10:00:00Z", "Mon"),
            ("2026-11-03T10:00:00Z", "3 Nov"),
            ("2025-11-03T10:00:00Z", "3 Nov 2025"),
            ("2026-11-11T09:30:00Z", "11:30")
        ]
        for (stamp, label) in cases {
            XCTAssertEqual(InboxRowTime.label(try date(stamp), now: now, calendar: Self.kyiv), label, stamp)
        }
        // Kyiv's day started at 22:00Z: 21:59Z is yesterday there.
        XCTAssertEqual(InboxRowTime.label(try date("2026-11-10T21:59:00Z"), now: now, calendar: Self.kyiv), "yesterday")
        XCTAssertEqual(InboxRowTime.label(try date("2026-11-10T22:00:00Z"), now: now, calendar: Self.kyiv), "00:00")
    }

    func testPreviewStripsMarkdown() {
        let body = """
        # Two threads need you

        > **Colleague A** asked about the `release`
        - first __point__
        * second
        + third
        12. numbered
        #hashtag stays
        -5 degrees stays
        """
        XCTAssertEqual(
            InboxRowText.preview(body),
            "Two threads need you Colleague A asked about the release first point second third numbered "
                + "#hashtag stays -5 degrees stays")
        XCTAssertEqual(InboxRowText.preview("  \n\n  "), "")
        XCTAssertEqual(InboxRowText.preview("a   b\t c"), "a b c")
    }

    func testPreviewCapsAt240() {
        let long = String(repeating: "word ", count: 100)
        let preview = InboxRowText.preview(long)
        XCTAssertEqual(preview.count, 240)
        XCTAssertTrue(preview.hasSuffix("…"))
        let exact = String(repeating: "x", count: 240)
        XCTAssertEqual(InboxRowText.preview(exact), exact, "240 characters fit")
    }

    // MARK: - Waiting for me

    func testWaitingForMeRow() throws {
        let feed = InboxFeedSnapshot(messages: [
            try message(1, who: "Colleague B", trigger: "dm", snippet: "Will you approve the budget?",
                        at: "2026-11-11T05:50:00Z"),
            try message(2, who: "Colleague C", whereText: "#eng", snippet: "Ship it?", at: "2026-11-10T23:00:00Z"),
            try message(3, who: "Colleague D", snippet: "old 1", at: "2026-11-10T12:00:00Z"),
            try message(4, who: "Colleague D", snippet: "old 2", at: "2026-11-09T12:00:00Z"),
            try message(5, who: "Colleague D", snippet: "old 3", at: "2026-11-01T12:00:00Z")
        ])
        let waiting = try card(7, automation: 3, title: "Waiting for me")
        let folders = InboxFolderMenuSnapshot(
            tree: .rootOnly, cards: [0: [waiting]],
            waitingForMe: WaitingForMeState(automationID: 3, messagesStandIn: false),
            peopleWaiting: PeopleWaitingCounts(open: 5, today: 2, week: 2, older: 1))

        let row = InboxFolderEntries.content(.artifact(waiting), try inputs(feed, folders))

        XCTAssertEqual(row.kind, .peopleWaiting)
        XCTAssertEqual(row.title, "Waiting for me")
        XCTAssertEqual(row.preview, "Colleague B in a DM: “Will you approve the budget?” · and 1 more today")
        XCTAssertEqual(row.meta, "1 older", "the Older section (7 × 24 h or more), from the uncapped counts")
        XCTAssertEqual(row.time, "07:50")
        XCTAssertEqual(row.pill, InboxRowPill(count: 2, tone: .needsYou))
        XCTAssertTrue(row.isUnread)
        XCTAssertNil(row.symbol)
    }

    func testWaitingForMeRowWithNothingToday() throws {
        let feed = InboxFeedSnapshot(messages: [
            try message(2, who: "Colleague C", whereText: "#eng", snippet: "Ship it?", at: "2026-11-10T12:00:00Z"),
            try message(3, who: "Colleague D", snippet: "older", at: "2026-11-09T12:00:00Z")
        ])
        let row = InboxFolderEntries.content(.legacyMessages, try inputs(feed, InboxFolderMenuSnapshot(
            tree: .rootOnly, peopleWaiting: PeopleWaitingCounts(open: 4, today: 0, week: 2, older: 2))))

        XCTAssertEqual(row.title, "Messages", "the stand-in")
        XCTAssertEqual(row.preview, "Colleague C in #eng: “Ship it?”", "the newest open one, no suffix")
        XCTAssertEqual(row.meta, "2 older")
        XCTAssertNil(row.pill)
        XCTAssertFalse(row.isUnread)

        let empty = InboxFolderEntries.content(.legacyMessages, try inputs())
        XCTAssertEqual(empty.preview, "Nothing waits on you")
        XCTAssertEqual(empty.meta, "")
        XCTAssertEqual(empty.time, "")
    }

    // MARK: - Morning brief

    func testBriefRowHasNoPill() throws {
        let briefing = try Briefing(row: Row([
            "id": 1, "user_id": "u", "date": "2026-11-11", "role": "",
            "attention": #"[{"text":"Answer Colleague B about the budget"}]"#, "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]", "model": "", "input_tokens": 0,
            "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1, "read_at": nil,
            "created_at": "2026-11-11T05:00:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
        let day = InboxDayCard(date: "2026-11-11", briefing: briefing, plan: nil, planDone: 0, planTotal: 0,
                               stamp: try date("2026-11-11T05:00:00Z"))
        let row = InboxFolderEntries.content(.legacyDay(day), try inputs())

        XCTAssertEqual(row.kind, .brief)
        XCTAssertEqual(row.title, "Morning brief")
        XCTAssertEqual(row.preview, "Answer Colleague B about the budget")
        XCTAssertEqual(row.meta, "Wed 11 Nov")
        XCTAssertEqual(row.time, "07:00")
        XCTAssertNil(row.pill)
        XCTAssertTrue(row.isUnread)

        let placeholder = InboxFolderEntries.content(
            .legacyDay(.placeholder(date: "2026-11-11", stamp: try date("2026-11-10T22:00:00Z"))), try inputs())
        XCTAssertEqual(placeholder.preview, "Not written yet")
        XCTAssertEqual(placeholder.time, "")
        XCTAssertNil(placeholder.pill)
        XCTAssertFalse(placeholder.isUnread)
    }

    // MARK: - Track my threads and Idea finder

    func testTracksAndIdeasRows() throws {
        func track(_ id: Int, _ text: String, unread: Bool, at stamp: String) throws -> InboxTrackCard {
            let row = Track(row: Row(["id": id, "text": text, "read_at": unread ? nil : "2026-11-01T00:00:00Z"]
                as [String: (any DatabaseValueConvertible)?]))
            return InboxTrackCard(track: row, lastEventAt: try date(stamp), newEventCount: 0)
        }
        func idea(_ id: Int, _ title: String, status: String, updated: String) -> Idea {
            Idea(row: Row(["id": id, "title": title, "status": status, "updated_at": updated]))
        }
        let feed = InboxFeedSnapshot(
            tracks: [
                try track(1, "Release acme 2.0", unread: true, at: "2026-11-11T04:00:00Z"),
                try track(2, "Budget review", unread: true, at: "2026-11-11T05:30:00Z"),
                try track(3, "Vendor contract", unread: true, at: "2026-11-10T09:00:00Z"),
                try track(4, "Read one", unread: false, at: "2026-11-11T06:00:00Z")
            ],
            ideas: [
                idea(1, "A shared glossary", status: "proposed", updated: "2026-11-10T09:00:00Z"),
                idea(2, "Weekly digest", status: "proposed", updated: "2026-11-11T05:00:00Z"),
                idea(3, "Kept one", status: "active", updated: "2026-11-11T06:00:00Z")
            ])

        let tracks = InboxFolderEntries.content(.legacyTracks, try inputs(feed))
        XCTAssertEqual(tracks.kind, .threads)
        XCTAssertEqual(tracks.title, "Track my threads")
        XCTAssertEqual(tracks.preview, "Budget review\nRelease acme 2.0")
        XCTAssertEqual(tracks.meta, "updated 2 min ago")
        XCTAssertEqual(tracks.time, "08:00")
        XCTAssertEqual(tracks.pill, InboxRowPill(count: 3, tone: .news))
        XCTAssertTrue(tracks.isUnread)

        let ideas = InboxFolderEntries.content(.legacyIdeas, try inputs(feed))
        XCTAssertEqual(ideas.kind, .ideas)
        XCTAssertEqual(ideas.title, "Idea finder")
        XCTAssertEqual(ideas.preview, "2 ideas to judge. Top one: “Weekly digest”")
        XCTAssertEqual(ideas.pill, InboxRowPill(count: 2, tone: .batch))
        XCTAssertTrue(ideas.isUnread)

        let quiet = InboxFeedSnapshot(tracks: [try track(4, "Read one", unread: false, at: "2026-11-11T06:00:00Z")])
        let noTracks = InboxFolderEntries.content(.legacyTracks, try inputs(quiet))
        XCTAssertEqual(noTracks.preview, "Nothing new in your threads")
        XCTAssertNil(noTracks.pill)
        XCTAssertFalse(noTracks.isUnread)
        let noIdeas = InboxFolderEntries.content(.legacyIdeas, try inputs(quiet))
        XCTAssertEqual(noIdeas.preview, "No ideas wait for a verdict")
        XCTAssertNil(noIdeas.pill)
        XCTAssertFalse(noIdeas.isUnread)
    }

    // MARK: - Artifacts and thread briefs

    func testOwnerArtifactRowUsesFolderIcon() throws {
        let release = InboxFolder(id: 5, kind: .owner, parentID: 0, slug: "release", title: "Release", icon: "flag")
        let plain = InboxFolder(id: 6, kind: .owner, parentID: 0, slug: "notes", title: "Notes")
        let tree = InboxFolderTree(revision: 1, folders: [InboxFolderTree.rootOnly.root, release, plain])
        let roundup = try card(1, body: "## Mail\n- **3** threads")
        let living = try card(2, title: "", key: "notes")
        let withRows = try card(3, blocks: #"{"v":1,"blocks":[]}"#)
        let folders = InboxFolderMenuSnapshot(
            tree: tree, cards: [5: [roundup, withRows], 6: [living]],
            refs: [3: [InboxRef(kind: .inboxItem, id: 9)]],
            refState: InboxRefState(shown: [InboxRef(kind: .inboxItem, id: 9)], waiting: [InboxRef(kind: .inboxItem, id: 9)]))

        let row = InboxFolderEntries.content(.artifact(roundup), try inputs(folders: folders))
        XCTAssertEqual(row.kind, .artifact)
        XCTAssertEqual(row.symbol, "flag")
        XCTAssertEqual(row.title, "Weekly mail roundup")
        XCTAssertEqual(row.preview, "Mail 3 threads")
        XCTAssertEqual(row.meta, "Your automation · run #12")
        XCTAssertEqual(row.time, "07:00")
        XCTAssertNil(row.pill, "a plain artifact has no pill")
        XCTAssertTrue(row.isUnread)

        let notes = InboxFolderEntries.content(.artifact(living), try inputs(folders: folders))
        XCTAssertEqual(notes.symbol, "folder", "an empty icon draws folder")
        XCTAssertEqual(notes.title, "Weekly", "no title: the automation's name")
        XCTAssertEqual(notes.meta, "Your automation · updated 1 h ago")

        let rows = InboxFolderEntries.content(.artifact(withRows), try inputs(folders: folders))
        XCTAssertEqual(rows.pill, InboxRowPill(count: 1, tone: .needsYou), "its row waits on the owner")
        XCTAssertTrue(rows.isUnread)
    }

    func testThreadBriefNeverUnread() throws {
        let action = AgentAction(row: Row([
            "id": 4, "tool": "brief_context", "reason": "Brief of a thread", "status": "applied",
            "applied_at": "2026-11-11T05:47:00Z"
        ]))
        let row = InboxFolderEntries.content(.brief(action), try inputs())
        XCTAssertEqual(row.kind, .threads)
        XCTAssertEqual(row.title, "Brief of a thread")
        XCTAssertEqual(row.preview, "")
        XCTAssertEqual(row.meta, "Thread brief")
        XCTAssertEqual(row.time, "07:47")
        XCTAssertNil(row.pill)
        XCTAssertFalse(row.isUnread)
    }
}

private extension InboxRowContentTests {
    func inputs(folders: InboxFolderMenuSnapshot) throws -> InboxFolderEntries.Inputs {
        try inputs(InboxFeedSnapshot(), folders)
    }
}
