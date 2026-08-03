import GRDB
import XCTest
@testable import WatchtowerKit

/// ReplicaToolbox mirrors the Go MCP v1 read tools (`internal/mcp/*.go` is
/// the contract) over the phone's replica, plus the two mobile write tools.
/// Pinned here: filter/ordering parity with the Go SQL, the MCP mirror rule
/// (unknown id → `null`, empty replica → `[]`, never an error), the queued
/// reply + outbox wiring of the write tools, and the near-midnight window
/// discipline for `list_upcoming_events` (injected `now`, never wall-clock).
final class ReplicaToolboxTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixtures {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let toolbox: ReplicaToolbox
    }

    /// Frozen near-midnight LOCAL instant (2026-07-06 23:30) — the boundary
    /// this project has burned on four times. Everything time-dependent in
    /// these tests derives from this injected value, never the wall clock.
    private func frozenNow() throws -> Date {
        try XCTUnwrap(Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 6, hour: 23, minute: 30)
        ))
    }

    private func makeFixtures() throws -> Fixtures {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let base = try frozenNow()
        let outbox = ActionOutbox(transport: transport, store: store) { base }
        let toolbox = ReplicaToolbox(store: store, outbox: outbox) { base }
        return Fixtures(transport: transport, store: store, toolbox: toolbox)
    }

    private func seed(_ store: ReplicaStore, _ records: [(kind: SliceKind, id: String, row: Row)]) throws {
        let changed = try records.map { record in
            CloudRecord(
                recordName: record.kind.recordName(id: record.id),
                zone: .data,
                kind: record.kind.rawValue,
                modifiedAt: Date(timeIntervalSince1970: 1_720_000_000),
                payload: try RowPayloadCoder.payload(from: record.row)
            )
        }
        try store.apply(CloudChangeBatch(
            changed: changed,
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)
        ))
    }

    private func execute(_ toolbox: ReplicaToolbox, _ name: String, _ json: String = "") async -> String {
        await toolbox.execute(name: name, inputJSON: Data(json.utf8))
    }

    private func objectResult(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func arrayResult(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private func ids(_ json: String) throws -> [Int] {
        try arrayResult(json).map { $0["id"] as? Int ?? -1 }
    }

    private let queuedReply = #"{"note":"will apply when your Mac processes the queue","status":"queued"}"#

    // MARK: - Row builders

    private func targetRow(
        id: Int,
        text: String = "target",
        status: String = "todo",
        priority: String = "medium",
        level: String = "week",
        ownership: String = "mine",
        periodStart: String = "2026-07-06",
        dueDate: String = "",
        createdAt: String = "2026-07-01T10:00:00Z"
    ) -> Row {
        Row([
            "id": id, "text": text, "intent": "do it", "level": level,
            "period_start": periodStart, "period_end": "2026-07-12",
            "status": status, "priority": priority, "ownership": ownership,
            "due_date": dueDate, "progress": 0.5, "source_type": "manual",
            "sub_items": #"[{"text":"step one","done":false}]"#,
            "notes": #"[{"text":"a note","created_at":"2026-07-01T10:00:00Z"}]"#,
            "created_at": createdAt, "updated_at": "2026-07-02T10:00:00Z"
        ])
    }

    private func trackRow(
        id: Int,
        text: String = "track",
        priority: String = "medium",
        ownership: String = "mine",
        hasUpdates: Bool = false,
        updatedAt: String = "2026-07-01T10:00:00Z",
        dismissedAt: String = ""
    ) -> Row {
        Row([
            "id": id, "text": text, "category": "task", "priority": priority,
            "ownership": ownership, "has_updates": hasUpdates,
            "updated_at": updatedAt, "dismissed_at": dismissedAt,
            "created_at": "2026-06-30T10:00:00Z", "context": "why it matters"
        ])
    }

    private func digestRow(
        id: Int,
        type: String = "channel",
        channelID: String = "C1",
        periodFrom: Double,
        periodTo: Double
    ) -> Row {
        Row([
            "id": id, "channel_id": channelID, "period_from": periodFrom,
            "period_to": periodTo, "type": type, "summary": "digest \(id) summary",
            "topics": #"["deploys"]"#, "decisions": "[]",
            "action_items": #"[{"title":"ship the fix"}]"#,
            "message_count": 12, "model": "haiku", "created_at": "2026-07-01T10:00:00Z"
        ])
    }

    private func briefingRow(id: Int, date: String) -> Row {
        Row([
            "id": id, "user_id": "U1", "date": date, "role": "ic",
            "attention": #"[{"text":"look at this"}]"#, "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]",
            "model": "haiku", "input_tokens": 1, "output_tokens": 1,
            "cost_usd": 0.01, "prompt_version": 1, "created_at": "2026-07-06T05:00:00Z"
        ])
    }

    private func personRow(id: Int, userID: String, periodTo: Double, summary: String = "profile") -> Row {
        Row([
            "id": id, "user_id": userID, "period_from": periodTo - 604_800,
            "period_to": periodTo, "message_count": 40, "channels_active": 3,
            "threads_initiated": 2, "threads_replied": 5, "avg_message_length": 80.0,
            "active_hours_json": "{}", "volume_change_pct": 0.0, "summary": summary,
            "communication_style": "driver", "decision_role": "decider",
            "red_flags": "[]", "highlights": #"["shipped the thing"]"#,
            "accomplishments": "[]", "communication_guide": "be brief",
            "decision_style": "fast", "tactics": "[]",
            "relationship_context": "peer", "status": "ok", "model": "haiku",
            "input_tokens": 1, "output_tokens": 1, "cost_usd": 0.01,
            "prompt_version": 1, "created_at": "2026-07-01T10:00:00Z"
        ])
    }

    private func eventRow(id: String, title: String, start: Date, end: Date) -> Row {
        let iso = ISO8601DateFormatter()
        return Row([
            "id": id, "calendar_id": "primary", "title": title,
            "start_time": iso.string(from: start), "end_time": iso.string(from: end),
            "location": "room 1", "event_status": "confirmed",
            "organizer_email": "boss@example.com",
            "attendees": #"[{"email":"a@example.com","display_name":"Aly","response_status":"accepted","slack_user_id":"U9"}]"#
        ])
    }

    /// The PROJECTION the publisher ships for a recording — no transcript_text,
    /// no segments_json, no audio_path, with the recap already resolved and the
    /// speaker roster already flattened to labels.
    private func transcriptRow(
        id: Int,
        title: String = "Weekly sync",
        eventID: String? = nil,
        eventTitle: String? = nil,
        createdAt: String = "2026-07-04T09:00:00Z",
        recapJSON: String = #"{"summary":"we shipped","key_decisions":["go"],"action_items":["ship"],"open_questions":["when"]}"#,
        notesMD: String = "# Notes",
        chaptersJSON: String = "",
        speakers: String = #"["Я","Speaker 2"]"#
    ) -> Row {
        Row([
            "id": id, "event_id": eventID, "event_title": eventTitle, "title": title,
            "duration_sec": 1_800, "lang_stats": #"{"ru":0.8,"en":0.2}"#,
            "notes_md": notesMD, "chapters_json": chaptersJSON,
            "recap_json": recapJSON, "speakers": speakers,
            "snippet": "so this is where we left off",
            "created_at": createdAt, "updated_at": "2026-07-04T10:00:00Z"
        ])
    }

    // MARK: - Tool definitions

    func testToolDefinitionsCoverContract() throws {
        let fixtures = try makeFixtures()
        let tools = fixtures.toolbox.tools

        XCTAssertEqual(tools.map(\.name), [
            "list_targets", "get_target",
            "get_today_briefing", "list_digests", "get_digest",
            "list_tracks", "get_track",
            "list_people", "get_person",
            "list_upcoming_events",
            "list_transcripts", "get_transcript",
            "create_task", "snooze_item"
        ])
        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            guard case let .object(schema) = tool.inputSchema else {
                XCTFail("\(tool.name) schema is not an object"); continue
            }
            XCTAssertEqual(schema["type"], .string("object"), tool.name)
        }

        // The documented desktop trap (SnoozeOption.targetCases): the model
        // must be told target snoozes are day-granularity on the desktop.
        let snooze = try XCTUnwrap(tools.first { $0.name == "snooze_item" })
        XCTAssertTrue(snooze.description.contains("day-granularity"))
    }

    // MARK: - MCP mirror rule: empty replica / unknown id → empty, never error

    func testEmptyReplicaReturnsEmptyArraysAndNulls() async throws {
        let fixtures = try makeFixtures()

        for name in ["list_targets", "list_digests", "list_tracks", "list_people",
                     "list_upcoming_events", "list_transcripts"] {
            let out = await execute(fixtures.toolbox, name)
            XCTAssertEqual(out, "[]", name)
        }
        for name in ["get_target", "get_digest", "get_track", "get_transcript"] {
            let out = await execute(fixtures.toolbox, name, #"{"id":1}"#)
            XCTAssertEqual(out, "null", name)
        }
        let person = await execute(fixtures.toolbox, "get_person", #"{"query":"U404"}"#)
        XCTAssertEqual(person, "null")
        let briefing = await execute(fixtures.toolbox, "get_today_briefing")
        XCTAssertEqual(briefing, "null")
    }

    // MARK: - list_targets

    func testListTargetsExcludesDoneByDefaultAndFiltersByStatus() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.target, "1", targetRow(id: 1, status: "todo")),
            (.target, "2", targetRow(id: 2, status: "done")),
            (.target, "3", targetRow(id: 3, status: "in_progress")),
            (.target, "4", targetRow(id: 4, status: "snoozed"))
        ])

        // Default: done/dismissed are excluded (Go GetTargets IncludeDone=false).
        let all = try ids(await execute(fixtures.toolbox, "list_targets"))
        XCTAssertEqual(Set(all), [1, 3, 4])

        // status filter parity.
        let todo = try ids(await execute(fixtures.toolbox, "list_targets", #"{"status":"todo"}"#))
        XCTAssertEqual(todo, [1])

        // status=done flips IncludeDone (Go parity) — without it this would be [].
        let done = try ids(await execute(fixtures.toolbox, "list_targets", #"{"status":"done"}"#))
        XCTAssertEqual(done, [2])
    }

    func testListTargetsFiltersByPriorityLevelOwnership() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.target, "1", targetRow(id: 1, priority: "high", level: "week", ownership: "mine")),
            (.target, "2", targetRow(id: 2, priority: "low", level: "day", ownership: "delegated"))
        ])

        let high = try ids(await execute(fixtures.toolbox, "list_targets", #"{"priority":"high"}"#))
        XCTAssertEqual(high, [1])
        let day = try ids(await execute(fixtures.toolbox, "list_targets", #"{"level":"day"}"#))
        XCTAssertEqual(day, [2])
        let delegated = try ids(await execute(fixtures.toolbox, "list_targets", #"{"ownership":"delegated"}"#))
        XCTAssertEqual(delegated, [2])
    }

    func testListTargetsOrderingMirrorsGoSQL() async throws {
        // Go ORDER BY: level rank, period_start ASC, priority rank,
        // dated-before-undated, due_date ASC, created_at DESC.
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.target, "1", targetRow(id: 1, level: "day", periodStart: "2026-07-06")),
            (.target, "2", targetRow(id: 2, level: "quarter", periodStart: "2026-07-01")),
            (.target, "3", targetRow(id: 3, priority: "low", level: "week", periodStart: "2026-07-06")),
            (.target, "4", targetRow(id: 4, priority: "high", level: "week", periodStart: "2026-07-06", dueDate: "2026-07-08T12:00")),
            (.target, "5", targetRow(id: 5, priority: "high", level: "week", periodStart: "2026-07-06"))
        ])

        let order = try ids(await execute(fixtures.toolbox, "list_targets"))
        XCTAssertEqual(order, [2, 4, 5, 3, 1])
    }

    func testListTargetsLimitAndInvalidEnum() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.target, "1", targetRow(id: 1)),
            (.target, "2", targetRow(id: 2))
        ])

        let limited = try ids(await execute(fixtures.toolbox, "list_targets", #"{"limit":1}"#))
        XCTAssertEqual(limited.count, 1)

        let invalid = await execute(fixtures.toolbox, "list_targets", #"{"status":"bogus"}"#)
        let error = try objectResult(invalid)
        XCTAssertEqual(
            error["error"] as? String,
            #"invalid status "bogus": must be one of todo|in_progress|blocked|done|dismissed|snoozed"#
        )
    }

    // MARK: - get_target

    func testGetTargetReturnsDetailAndNullForUnknownID() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [(.target, "7", targetRow(id: 7, text: "Ship the toolbox"))])

        let detail = try objectResult(await execute(fixtures.toolbox, "get_target", #"{"id":7}"#))
        XCTAssertEqual(detail["id"] as? Int, 7)
        XCTAssertEqual(detail["text"] as? String, "Ship the toolbox")
        XCTAssertEqual(detail["intent"] as? String, "do it")
        // sub_items/notes come back as parsed JSON, not embedded strings.
        let subItems = try XCTUnwrap(detail["sub_items"] as? [[String: Any]])
        XCTAssertEqual(subItems.first?["text"] as? String, "step one")

        let missing = await execute(fixtures.toolbox, "get_target", #"{"id":404}"#)
        XCTAssertEqual(missing, "null")
    }

    // MARK: - get_today_briefing

    func testGetTodayBriefingUsesInjectedLocalDate() async throws {
        let fixtures = try makeFixtures()
        // frozenNow is 23:30 LOCAL on 2026-07-06 — "today" must be computed
        // from the injected instant in the local calendar, never wall-clock.
        try seed(fixtures.store, [
            (.briefing, "1", briefingRow(id: 1, date: "2026-07-05")),
            (.briefing, "2", briefingRow(id: 2, date: "2026-07-06"))
        ])

        let out = try objectResult(await execute(fixtures.toolbox, "get_today_briefing"))
        XCTAssertEqual(out["id"] as? Int, 2)
        XCTAssertEqual(out["date"] as? String, "2026-07-06")
        let attention = try XCTUnwrap(out["attention"] as? [[String: Any]])
        XCTAssertEqual(attention.first?["text"] as? String, "look at this")
    }

    func testGetTodayBriefingNullWhenOnlyOlderBriefingsExist() async throws {
        let fixtures = try makeFixtures()
        // Go GetBriefing returns nil (→ JSON null) rather than a stale briefing.
        try seed(fixtures.store, [(.briefing, "1", briefingRow(id: 1, date: "2026-07-05"))])

        let out = await execute(fixtures.toolbox, "get_today_briefing")
        XCTAssertEqual(out, "null")
    }

    // MARK: - list_digests / get_digest

    func testListDigestsMostRecentFirstWithTypeFilterAndLimit() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.digest, "1", digestRow(id: 1, type: "channel", periodFrom: 1_000, periodTo: 2_000)),
            (.digest, "2", digestRow(id: 2, type: "daily", periodFrom: 3_000, periodTo: 4_000)),
            (.digest, "3", digestRow(id: 3, type: "channel", periodFrom: 5_000, periodTo: 6_000))
        ])

        // Go ORDER BY period_to DESC, period_from DESC.
        let all = try ids(await execute(fixtures.toolbox, "list_digests"))
        XCTAssertEqual(all, [3, 2, 1])

        let daily = try ids(await execute(fixtures.toolbox, "list_digests", #"{"type":"daily"}"#))
        XCTAssertEqual(daily, [2])

        let limited = try ids(await execute(fixtures.toolbox, "list_digests", #"{"limit":1}"#))
        XCTAssertEqual(limited, [3])

        let invalid = await execute(fixtures.toolbox, "list_digests", #"{"since":"not-a-date"}"#)
        XCTAssertEqual(
            try objectResult(invalid)["error"] as? String,
            #"invalid since "not-a-date": use YYYY-MM-DD or RFC3339"#
        )
    }

    func testGetDigestIncludesFullSummaryAndNullForUnknown() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [(.digest, "5", digestRow(id: 5, periodFrom: 1_000, periodTo: 2_000))])

        let list = try arrayResult(await execute(fixtures.toolbox, "list_digests"))
        XCTAssertNil(list.first?["summary"], "list stays compact; the full summary is get_digest's job")

        let detail = try objectResult(await execute(fixtures.toolbox, "get_digest", #"{"id":5}"#))
        XCTAssertEqual(detail["summary"] as? String, "digest 5 summary")
        // Owner decision: action_items ride the detail (parsed, not raw JSON string).
        let actionItems = try XCTUnwrap(detail["action_items"] as? [[String: Any]])
        XCTAssertEqual(actionItems.first?["title"] as? String, "ship the fix")

        let missing = await execute(fixtures.toolbox, "get_digest", #"{"id":404}"#)
        XCTAssertEqual(missing, "null")
    }

    // MARK: - list_tracks / get_track

    func testListTracksActiveByDefaultOrderedByUpdatesThenRecency() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.track, "1", trackRow(id: 1, updatedAt: "2026-07-02T10:00:00Z")),
            (.track, "2", trackRow(id: 2, hasUpdates: true, updatedAt: "2026-07-01T10:00:00Z")),
            (.track, "3", trackRow(id: 3, updatedAt: "2026-07-03T10:00:00Z")),
            (.track, "4", trackRow(id: 4, dismissedAt: "2026-07-01T10:00:00Z"))
        ])

        // Go ORDER BY has_updates DESC, updated_at DESC; dismissed excluded.
        let all = try ids(await execute(fixtures.toolbox, "list_tracks"))
        XCTAssertEqual(all, [2, 3, 1])

        let high = try ids(await execute(fixtures.toolbox, "list_tracks", #"{"priority":"high"}"#))
        XCTAssertEqual(high, [])

        let invalid = await execute(fixtures.toolbox, "list_tracks", #"{"ownership":"theirs"}"#)
        XCTAssertEqual(
            try objectResult(invalid)["error"] as? String,
            #"invalid ownership "theirs": must be one of mine|delegated|watching"#
        )
    }

    func testGetTrackReturnsDetailAndNullForUnknownID() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [(.track, "9", trackRow(id: 9, text: "migration saga"))])

        let detail = try objectResult(await execute(fixtures.toolbox, "get_track", #"{"id":9}"#))
        XCTAssertEqual(detail["id"] as? Int, 9)
        XCTAssertEqual(detail["text"] as? String, "migration saga")
        XCTAssertEqual(detail["context"] as? String, "why it matters")

        let missing = await execute(fixtures.toolbox, "get_track", #"{"id":404}"#)
        XCTAssertEqual(missing, "null")
    }

    // MARK: - list_people / get_person

    func testListPeopleNewestFirstAndGetPersonPicksLatestCard() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.personCard, "1", personRow(id: 1, userID: "U1", periodTo: 1_000, summary: "old card")),
            (.personCard, "2", personRow(id: 2, userID: "U1", periodTo: 2_000, summary: "new card")),
            (.personCard, "3", personRow(id: 3, userID: "U2", periodTo: 1_500))
        ])

        // Go ORDER BY period_to DESC, period_from DESC.
        let all = try ids(await execute(fixtures.toolbox, "list_people"))
        XCTAssertEqual(all, [2, 3, 1])

        // Go GetLatestPeopleCard: ORDER BY period_to DESC LIMIT 1.
        let person = try objectResult(await execute(fixtures.toolbox, "get_person", #"{"query":"U1"}"#))
        XCTAssertEqual(person["summary"] as? String, "new card")
        XCTAssertEqual(person["user_id"] as? String, "U1")

        // Name search needs the users table, which the replica does not carry:
        // an unmatched query is null (MCP mirror rule), not an error.
        let unknown = await execute(fixtures.toolbox, "get_person", #"{"query":"Alice"}"#)
        XCTAssertEqual(unknown, "null")
    }

    // MARK: - Account-namespaced Slack ids (get_person / list_digests channel)

    /// Stored Slack ids are account-namespaced (`"1:U9"`). Both id lookups must
    /// accept the canonical form other tools return AND a bare raw id, without
    /// ever matching a different account's id or a prefix of one.
    func testGetPersonAcceptsNamespacedAndBareUserID() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.personCard, "1", personRow(id: 1, userID: "1:U9", periodTo: 1_000, summary: "namespaced card"))
        ])

        // Round-trip: the id exactly as list_people/get_person hand it back.
        let canonical = try objectResult(await execute(fixtures.toolbox, "get_person", #"{"query":"1:U9"}"#))
        XCTAssertEqual(canonical["summary"] as? String, "namespaced card")
        XCTAssertEqual(canonical["user_id"] as? String, "1:U9", "the namespaced id is returned verbatim, never stripped")

        // Bare raw id: the form a model remembers from a Slack link or a human.
        let bare = try objectResult(await execute(fixtures.toolbox, "get_person", #"{"query":"U9"}"#))
        XCTAssertEqual(bare["summary"] as? String, "namespaced card")

        // Another account's namespaced id is a MISS, not a raw-part match.
        let otherAccount = await execute(fixtures.toolbox, "get_person", #"{"query":"2:U9"}"#)
        XCTAssertEqual(otherAccount, "null")
        // Neither the account prefix nor a prefix of the raw id may match.
        let prefixOnly = await execute(fixtures.toolbox, "get_person", #"{"query":"1"}"#)
        XCTAssertEqual(prefixOnly, "null")
        let rawPrefix = await execute(fixtures.toolbox, "get_person", #"{"query":"U"}"#)
        XCTAssertEqual(rawPrefix, "null")
    }

    /// A bare query is genuinely ambiguous once two accounts carry a card for
    /// the same raw user id. Documented resolution: `personOrder` decides, so
    /// the newest card across accounts wins — the same rule that already picks
    /// between several cards of one user. A namespaced query still pins the account.
    func testGetPersonBareQueryAcrossAccountsPicksNewestCard() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.personCard, "1", personRow(id: 1, userID: "1:U9", periodTo: 1_000, summary: "account one")),
            (.personCard, "2", personRow(id: 2, userID: "2:U9", periodTo: 2_000, summary: "account two"))
        ])

        let ambiguous = try objectResult(await execute(fixtures.toolbox, "get_person", #"{"query":"U9"}"#))
        XCTAssertEqual(ambiguous["summary"] as? String, "account two")
        XCTAssertEqual(ambiguous["user_id"] as? String, "2:U9", "the reply names the account it resolved to")

        let pinned = try objectResult(await execute(fixtures.toolbox, "get_person", #"{"query":"1:U9"}"#))
        XCTAssertEqual(pinned["summary"] as? String, "account one")
    }

    func testListDigestsChannelFilterAcceptsNamespacedAndBareID() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.digest, "1", digestRow(id: 1, channelID: "1:C1", periodFrom: 1_000, periodTo: 2_000)),
            (.digest, "2", digestRow(id: 2, channelID: "2:C1", periodFrom: 3_000, periodTo: 4_000)),
            (.digest, "3", digestRow(id: 3, channelID: "1:C10", periodFrom: 5_000, periodTo: 6_000))
        ])

        let canonical = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":"1:C1"}"#))
        XCTAssertEqual(canonical, [1])

        // Bare id: every account's channel with that raw id (list tool — no
        // ambiguity to resolve), newest first.
        let bare = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":"C1"}"#))
        XCTAssertEqual(bare, [2, 1])

        // Still equality on the raw part — never a prefix match on "1:C10".
        let bareLonger = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":"C10"}"#))
        XCTAssertEqual(bareLonger, [3])
        let wrongAccount = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":"2:C10"}"#))
        XCTAssertEqual(wrongAccount, [])
    }

    /// The asymmetry is deliberate: the QUERY is never stripped, so a replica
    /// still carrying pre-migration BARE rows answers a namespaced query with
    /// nothing rather than guessing which account the row belongs to.
    func testNamespacedQueryMissesBareStoredID() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.digest, "1", digestRow(id: 1, channelID: "C1", periodFrom: 1_000, periodTo: 2_000))
        ])

        let namespaced = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":"1:C1"}"#))
        XCTAssertEqual(namespaced, [])
        // The same row still answers its own bare form.
        let bare = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":"C1"}"#))
        XCTAssertEqual(bare, [1])
    }

    /// An explicitly empty channel is "no filter" on the list side — the
    /// opposite of `get_person`'s empty query, which is a miss.
    func testListDigestsEmptyChannelFilterReturnsEverything() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.digest, "1", digestRow(id: 1, channelID: "1:C1", periodFrom: 1_000, periodTo: 2_000)),
            (.digest, "2", digestRow(id: 2, channelID: "2:C2", periodFrom: 3_000, periodTo: 4_000))
        ])

        let empty = try ids(await execute(fixtures.toolbox, "list_digests", #"{"channel":""}"#))
        XCTAssertEqual(empty, [2, 1])
    }

    /// The shared `matches` helper backs 8 non-id filters; loosening it for
    /// everyone would make "1:high" a valid priority. Pinned: an id-shaped
    /// value stays a plain mismatch on a non-id filter.
    func testNonSlackIDFiltersKeepExactEquality() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.digest, "1", digestRow(id: 1, type: "channel", periodFrom: 1_000, periodTo: 2_000)),
            (.target, "1", targetRow(id: 1, priority: "high"))
        ])

        let typed = await execute(fixtures.toolbox, "list_digests", #"{"type":"1:channel"}"#)
        XCTAssertNotNil(try objectResult(typed)["error"], "an id-shaped type is invalid, never a namespaced match")
        let priced = await execute(fixtures.toolbox, "list_targets", #"{"priority":"1:high"}"#)
        XCTAssertNotNil(try objectResult(priced)["error"])
    }

    /// An empty query must stay a miss: `matchesSlackID`'s empty-means-no-filter
    /// rule is list-tool semantics, and inheriting it here would hand the model
    /// an arbitrary person's card for a blank lookup.
    func testGetPersonEmptyQueryIsNullNotAnArbitraryCard() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.personCard, "1", personRow(id: 1, userID: "1:U9", periodTo: 1_000))
        ])

        let empty = await execute(fixtures.toolbox, "get_person", #"{"query":""}"#)
        XCTAssertEqual(empty, "null")
    }

    /// The id-shape truth has to reach the model: descriptions that promise a
    /// bare "U…" are what caused the always-null lookups in the first place.
    func testIDToolDescriptionsDocumentNamespacedForm() throws {
        let fixtures = try makeFixtures()
        let tools = fixtures.toolbox.tools

        let person = try XCTUnwrap(tools.first { $0.name == "get_person" })
        XCTAssertTrue(person.description.contains("<account>:"), person.description)
        let digests = try XCTUnwrap(tools.first { $0.name == "list_digests" })
        guard case let .object(schema) = digests.inputSchema,
              let propertiesValue = schema["properties"],
              case let .object(properties) = propertiesValue,
              let channelValue = properties["channel"],
              case let .object(channel) = channelValue,
              let docValue = channel["description"],
              case let .string(channelDoc) = docValue else {
            return XCTFail("list_digests channel property has no description")
        }
        XCTAssertTrue(channelDoc.contains("<account>:"), channelDoc)
    }

    // MARK: - list_upcoming_events

    func testListUpcomingEventsWindowAcrossMidnightWithFrozenNow() async throws {
        let fixtures = try makeFixtures()
        let now = try frozenNow() // 23:30 local — the burned-four-times boundary

        try seed(fixtures.store, [
            (.calendarEvent, "past", eventRow(
                id: "past", title: "ended earlier",
                start: now.addingTimeInterval(-7_200), end: now.addingTimeInterval(-3_600))),
            (.calendarEvent, "live", eventRow(
                id: "live", title: "in progress",
                start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(1_800))),
            (.calendarEvent, "tonight", eventRow(
                id: "tonight", title: "before midnight",
                start: now.addingTimeInterval(900), end: now.addingTimeInterval(2_700))),
            (.calendarEvent, "tomorrow", eventRow(
                id: "tomorrow", title: "after midnight",
                start: now.addingTimeInterval(7_200), end: now.addingTimeInterval(10_800))),
            (.calendarEvent, "edge", eventRow(
                id: "edge", title: "starts exactly at now+48h",
                start: now.addingTimeInterval(48 * 3_600), end: now.addingTimeInterval(48 * 3_600 + 1_800))),
            (.calendarEvent, "far", eventRow(
                id: "far", title: "beyond 48h",
                start: now.addingTimeInterval(49 * 3_600), end: now.addingTimeInterval(50 * 3_600)))
        ])

        // Go parity: end_time >= now AND start_time <= now+48h — an event
        // already in progress counts, the exact +48h boundary is INCLUSIVE
        // (start_time <= to), ordered by start_time ascending.
        let titles = try arrayResult(await execute(fixtures.toolbox, "list_upcoming_events"))
            .map { $0["id"] as? String ?? "" }
        XCTAssertEqual(titles, ["live", "tonight", "tomorrow", "edge"])

        // Narrow window: only events starting within the next hour (+ live one).
        let narrow = try arrayResult(await execute(fixtures.toolbox, "list_upcoming_events", #"{"hours":1}"#))
            .map { $0["id"] as? String ?? "" }
        XCTAssertEqual(narrow, ["live", "tonight"])
    }

    func testListUpcomingEventsShapesAttendees() async throws {
        let fixtures = try makeFixtures()
        let now = try frozenNow()
        try seed(fixtures.store, [
            (.calendarEvent, "e1", eventRow(
                id: "e1", title: "standup",
                start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_200)))
        ])

        let events = try arrayResult(await execute(fixtures.toolbox, "list_upcoming_events"))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["title"] as? String, "standup")
        let attendees = try XCTUnwrap(event["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.first?["display_name"] as? String, "Aly")
        XCTAssertEqual(attendees.first?["response_status"] as? String, "accepted")
        XCTAssertNil(event["raw_json"], "raw_json must not be dumped to the model")
    }

    // MARK: - list_transcripts / get_transcript

    func testListTranscriptsOrdersNewestFirstAndFiltersByEvent() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.meetingTranscript, "1", transcriptRow(id: 1, title: "older", createdAt: "2026-07-01T09:00:00Z")),
            (.meetingTranscript, "2", transcriptRow(
                id: 2, title: "linked", eventID: "evt-9", eventTitle: "Design review",
                createdAt: "2026-07-03T09:00:00Z")),
            (.meetingTranscript, "3", transcriptRow(id: 3, title: "newest", createdAt: "2026-07-05T09:00:00Z"))
        ])

        // Go ListMeetingTranscripts ORDER BY created_at DESC, id DESC.
        let order = try ids(await execute(fixtures.toolbox, "list_transcripts"))
        XCTAssertEqual(order, [3, 2, 1])

        // event_id is an exact match; an ad-hoc recording (event_id NULL) can
        // never satisfy it, exactly as the Go SQL's `event_id = ?` cannot.
        let byEvent = try arrayResult(await execute(fixtures.toolbox, "list_transcripts", #"{"event_id":"evt-9"}"#))
        XCTAssertEqual(byEvent.map { $0["id"] as? Int }, [2])
        XCTAssertEqual(byEvent.first?["event_title"] as? String, "Design review")
        let byMissingEvent = try ids(await execute(fixtures.toolbox, "list_transcripts", #"{"event_id":"evt-none"}"#))
        XCTAssertEqual(byMissingEvent, [])
    }

    func testListTranscriptsDateBoundsAndInvalidDates() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.meetingTranscript, "1", transcriptRow(id: 1, createdAt: "2026-07-01T09:00:00Z")),
            (.meetingTranscript, "2", transcriptRow(id: 2, createdAt: "2026-07-03T23:30:00Z")),
            (.meetingTranscript, "3", transcriptRow(id: 3, createdAt: "2026-07-05T09:00:00Z"))
        ])

        // Go dateBound: `from` widens to T00:00:00Z, `to` to T23:59:59Z — so a
        // recording made late on the `to` day is still inside the window.
        let oneDay = try ids(await execute(
            fixtures.toolbox, "list_transcripts", #"{"from":"2026-07-03","to":"2026-07-03"}"#))
        XCTAssertEqual(oneDay, [2])
        let fromOnly = try ids(await execute(fixtures.toolbox, "list_transcripts", #"{"from":"2026-07-03"}"#))
        XCTAssertEqual(fromOnly, [3, 2])

        // Invalid bounds are input errors with Go's message; `from` is reported
        // first (firstError's order).
        let badFrom = await execute(fixtures.toolbox, "list_transcripts", #"{"from":"07/03/2026","to":"nope"}"#)
        XCTAssertEqual(
            try objectResult(badFrom)["error"] as? String,
            #"invalid from date "07/03/2026": must be YYYY-MM-DD"#
        )
        let badTo = await execute(fixtures.toolbox, "list_transcripts", #"{"to":"nope"}"#)
        XCTAssertEqual(
            try objectResult(badTo)["error"] as? String,
            #"invalid to date "nope": must be YYYY-MM-DD"#
        )
        // A well-shaped but impossible date is rejected too (Go's time.Parse
        // rejects month 13; a lenient parser would roll it into 2027).
        let rolled = await execute(fixtures.toolbox, "list_transcripts", #"{"from":"2026-13-01"}"#)
        XCTAssertEqual(
            try objectResult(rolled)["error"] as? String,
            #"invalid from date "2026-13-01": must be YYYY-MM-DD"#
        )
    }

    /// The slice has no transcript text by construction, so the detail hands
    /// back what the phone does hold — recap fields, chapters, notes, speakers,
    /// snippet — and never a `transcript_text` key that would read as empty.
    func testGetTranscriptReturnsRecapNotesAndSnippetButNoText() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.meetingTranscript, "7", transcriptRow(
                id: 7, title: "Weekly sync", eventID: "evt-1", eventTitle: "Weekly sync (cal)",
                chaptersJSON: #"{"overall_summary":"two topics","chapters":[{"title":"Intro"}]}"#))
        ])

        let detail = try objectResult(await execute(fixtures.toolbox, "get_transcript", #"{"id":7}"#))
        XCTAssertEqual(detail["id"] as? Int, 7)
        XCTAssertEqual(detail["event_id"] as? String, "evt-1")
        XCTAssertEqual(detail["event_title"] as? String, "Weekly sync (cal)")
        XCTAssertEqual(detail["duration_sec"] as? Int, 1_800)
        XCTAssertEqual(detail["summary"] as? String, "we shipped")
        XCTAssertEqual(detail["key_decisions"] as? [String], ["go"])
        XCTAssertEqual(detail["action_items"] as? [String], ["ship"])
        XCTAssertEqual(detail["open_questions"] as? [String], ["when"])
        XCTAssertEqual(detail["notes_md"] as? String, "# Notes")
        XCTAssertEqual(detail["speakers"] as? [String], ["Я", "Speaker 2"])
        XCTAssertEqual(detail["snippet"] as? String, "so this is where we left off")
        let chapters = try XCTUnwrap(detail["chapters"] as? [String: Any])
        XCTAssertEqual(chapters["overall_summary"] as? String, "two topics")
        XCTAssertNil(detail["transcript_text"], "the full text is not synced — the key must be absent")
        XCTAssertNil(detail["segments_json"])
        XCTAssertNil(detail["audio_path"])
    }

    /// A recording with no recap and no chapters is still a valid answer: empty
    /// recap fields, `chapters` null (an object column, so NOT `[]`), and an
    /// ad-hoc recording's absent event reads as null, not "".
    ///
    /// The nullable columns are seeded as SQL NULL, which is what the publisher
    /// actually emits for a fresh recording — the model's `?? ""` defaulting is
    /// the thing under test here.
    func testGetTranscriptWithoutRecapOrChaptersIsStillUsable() async throws {
        let fixtures = try makeFixtures()
        let nulls = Row([
            "id": 1, "event_id": nil, "event_title": nil, "title": "Ad-hoc note to self",
            "duration_sec": 90, "lang_stats": "", "notes_md": nil, "chapters_json": nil,
            "recap_json": nil, "speakers": "[]", "snippet": "just me talking",
            "created_at": "2026-07-04T09:00:00Z", "updated_at": "2026-07-04T09:00:00Z"
        ])
        try seed(fixtures.store, [(.meetingTranscript, "1", nulls)])

        let detail = try objectResult(await execute(fixtures.toolbox, "get_transcript", #"{"id":1}"#))
        XCTAssertEqual(detail["title"] as? String, "Ad-hoc note to self")
        XCTAssertEqual(detail["duration_sec"] as? Int, 90)
        XCTAssertEqual(detail["summary"] as? String, "")
        XCTAssertEqual(detail["notes_md"] as? String, "")
        XCTAssertEqual(detail["key_decisions"] as? [String], [])
        XCTAssertEqual(detail["speakers"] as? [String], [])
        XCTAssertTrue(detail["chapters"] is NSNull, "an absent object column must be null, not []")
        XCTAssertTrue(detail["event_id"] is NSNull, "an ad-hoc recording has no event")
        XCTAssertTrue(detail["event_title"] is NSNull)
    }

    /// A partial recap (Go's json.Unmarshal tolerates missing keys) must still
    /// yield its summary instead of decoding to nothing.
    func testPartialRecapJSONStillYieldsSummary() async throws {
        let fixtures = try makeFixtures()
        try seed(fixtures.store, [
            (.meetingTranscript, "1", transcriptRow(id: 1, recapJSON: #"{"summary":"only a summary"}"#)),
            (.meetingTranscript, "2", transcriptRow(id: 2, recapJSON: "{not json"))
        ])

        let rows = try arrayResult(await execute(fixtures.toolbox, "list_transcripts"))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as? Int ?? -1, $0) })
        XCTAssertEqual(byID[1]?["summary"] as? String, "only a summary")
        XCTAssertEqual(byID[2]?["summary"] as? String, "", "an unreadable recap must not hide the recording")
        XCTAssertEqual(byID[2]?["title"] as? String, "Weekly sync")
    }

    /// Both descriptions must tell the model the full text is NOT on the phone —
    /// otherwise it invents quotes instead of routing the ask to the Mac (the
    /// MobileSystemPrompt honesty rule for raw Slack messages, applied here).
    func testTranscriptToolDescriptionsDisclaimTheMissingFullText() throws {
        let fixtures = try makeFixtures()
        for name in ["list_transcripts", "get_transcript"] {
            let tool = try XCTUnwrap(fixtures.toolbox.tools.first { $0.name == name })
            XCTAssertTrue(tool.description.contains("full transcript text is NOT on the phone")
                          || tool.description.contains("FULL transcript text is not synced"),
                          "\(name): \(tool.description)")
            XCTAssertTrue(tool.description.contains("Mac"), name)
        }
    }

    // MARK: - create_task

    func testCreateTaskEnqueuesTaskCreateAndReturnsQueuedReply() async throws {
        let fixtures = try makeFixtures()

        let reply = await execute(fixtures.toolbox, "create_task", #"{"text":"Buy milk"}"#)
        XCTAssertEqual(reply, queuedReply)

        let pending = try fixtures.store.pendingActions()
        XCTAssertEqual(pending.count, 1)
        let row = try XCTUnwrap(pending.first)
        XCTAssertEqual(row.action.kind, .taskCreate)
        XCTAssertNil(row.entityRecordName)

        let records = try await fixtures.transport.changes(in: .relay, since: nil).changed
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.kind, RelayRecordKind.action.rawValue)
        let wire = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        XCTAssertEqual(wire.kind, .taskCreate)
        XCTAssertNil(wire.entityID)
        XCTAssertEqual(wire.params["text"], .string("Buy milk"))
    }

    func testCreateTaskRejectsEmptyText() async throws {
        let fixtures = try makeFixtures()

        let reply = await execute(fixtures.toolbox, "create_task", #"{"text":"   "}"#)
        XCTAssertEqual(try objectResult(reply)["error"] as? String, "text is required")
        XCTAssertTrue(try fixtures.store.pendingActions().isEmpty)
    }

    // MARK: - snooze_item

    func testSnoozeItemTargetUsesPlanFourRecordNameConvention() async throws {
        let fixtures = try makeFixtures()

        let reply = await execute(
            fixtures.toolbox, "snooze_item",
            #"{"entity_type":"target","id":42,"until":"2026-07-10T00:00:00Z"}"#
        )
        XCTAssertEqual(reply, queuedReply)

        let row = try XCTUnwrap(fixtures.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .targetSnooze)
        XCTAssertEqual(row.entityRecordName, "target-42")

        let records = try await fixtures.transport.changes(in: .relay, since: nil).changed
        let wire = try RelayCoder.makeDecoder().decode(
            ActionRequestPayload.self, from: try XCTUnwrap(records.first).payload
        )
        XCTAssertEqual(wire.kind, .targetSnooze)
        XCTAssertEqual(wire.entityID, "42")
        XCTAssertEqual(wire.params["snooze_until"], .string("2026-07-10T00:00:00Z"))
    }

    func testSnoozeItemInboxItemKindAndRecordName() async throws {
        let fixtures = try makeFixtures()

        let reply = await execute(
            fixtures.toolbox, "snooze_item",
            #"{"entity_type":"inbox_item","id":7,"until":"2026-07-08T09:00:00Z"}"#
        )
        XCTAssertEqual(reply, queuedReply)

        let row = try XCTUnwrap(fixtures.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .inboxSnooze)
        XCTAssertEqual(row.entityRecordName, "inbox_item-7")
        XCTAssertEqual(row.action.entityID, "7")
    }

    func testSnoozeItemRejectsBadEntityTypeAndBadUntil() async throws {
        let fixtures = try makeFixtures()

        let badType = await execute(
            fixtures.toolbox, "snooze_item",
            #"{"entity_type":"track","id":1,"until":"2026-07-10T00:00:00Z"}"#
        )
        XCTAssertEqual(
            try objectResult(badType)["error"] as? String,
            #"invalid entity_type "track": must be one of target|inbox_item"#
        )

        let badUntil = await execute(
            fixtures.toolbox, "snooze_item",
            #"{"entity_type":"target","id":1,"until":"next tuesday"}"#
        )
        XCTAssertEqual(
            try objectResult(badUntil)["error"] as? String,
            #"invalid until "next tuesday": use ISO8601, e.g. 2026-07-10T00:00:00Z"#
        )

        XCTAssertTrue(try fixtures.store.pendingActions().isEmpty, "no action may be enqueued on invalid input")
    }

    // MARK: - Malformed input / unknown tool

    func testMalformedInputReturnsErrorJSONNotACrash() async throws {
        let fixtures = try makeFixtures()

        let out = await execute(fixtures.toolbox, "list_targets", "this is not json")
        let error = try XCTUnwrap(try objectResult(out)["error"] as? String)
        XCTAssertTrue(error.hasPrefix("invalid tool input"), error)

        // Missing required field on a get tool is also an input error, not a trap.
        let missingID = await execute(fixtures.toolbox, "get_target", #"{"nope":true}"#)
        XCTAssertNotNil(try objectResult(missingID)["error"])
    }

    func testEmptyInputMeansDefaultsAndUnknownToolErrors() async throws {
        let fixtures = try makeFixtures()

        let out = await fixtures.toolbox.execute(name: "list_targets", inputJSON: Data())
        XCTAssertEqual(out, "[]")

        let unknown = await execute(fixtures.toolbox, "does_not_exist")
        XCTAssertEqual(try objectResult(unknown)["error"] as? String, #"unknown tool "does_not_exist""#)
    }

    // MARK: - WireJSON literal sugar (Task 3 carried instruction)

    func testWireJSONLiteralsBuildTheSameValuesAsExplicitCases() {
        let literal: WireJSON = [
            "type": "object",
            "count": 2,
            "flag": true,
            "items": ["a", "b"]
        ]
        let explicit = WireJSON.object([
            "type": .string("object"),
            "count": .int(2),
            "flag": .bool(true),
            "items": .array([.string("a"), .string("b")])
        ])
        XCTAssertEqual(literal, explicit)
    }
}
