import Foundation

/// The MCP v1 tool set mirrored over the phone's replica, for the BYOK
/// direct-API agent (Plan 5). The Go MCP server (`internal/mcp/targets.go`,
/// `digests.go`, `people.go`) is the CONTRACT: tool names, filters, defaults,
/// and ordering are copied from its registrations; where the Go filters on DB
/// columns this mirror filters in memory over `fetchAll` results (replica
/// slices are small by design — Plan 5 decision 4).
///
/// Contract deviations, all deliberate:
/// - Unknown id / absent data → JSON `null` (or `[]` for lists), NEVER an
///   error. The Go server surfaces "no target with id N" as a tool error;
///   the mobile mirror pins the softer rule from the plan so the model can
///   keep working offline without retry loops.
/// - Output is compact snake_case dicts (id, text/title, status, dates, and
///   the parsed JSON columns the Go descriptions promise), not whole-row
///   dumps — the replica rows carry sync metadata the model has no use for.
/// - `get_person` matches by Slack user id ONLY: the Go fallback name search
///   reads the `users` table, which is not a replica slice. Documented gap.
/// - Slack-id filters also accept a BARE raw id (`"U0456"` for a stored
///   `"1:U0456"`), which Go does not — the model rarely knows the account
///   prefix; a namespaced query still pins one account.
/// - Two write tools (`create_task`, `snooze_item`) extend the read-only MCP
///   set; they enqueue through `ActionOutbox` and land in the pending overlay
///   like any swipe action.
///
/// `execute` NEVER throws: internal failures become `{"error": "..."}`
/// strings for the model (the caller maps them to `tool_result` blocks).
/// All output encoding uses `.sortedKeys`, so replies are deterministic.
public struct ReplicaToolbox: Sendable {
    private let store: ReplicaStore
    private let outbox: ActionOutbox
    /// Injected clock — `get_today_briefing` and `list_upcoming_events` are
    /// time-window tools and must never read the wall clock directly.
    private let now: @Sendable () -> Date

    public init(
        store: ReplicaStore,
        outbox: ActionOutbox,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outbox = outbox
        self.now = now
    }

    public var tools: [APITool] { Self.toolDefinitions }

    public func execute(name: String, inputJSON: Data) async -> String {
        do {
            return try await dispatch(name: name, inputJSON: inputJSON)
        } catch let error as ToolError {
            return Self.errorJSON(error.message)
        } catch {
            return Self.errorJSON("tool \(name) failed: \(String(describing: error))")
        }
    }

    private func dispatch(name: String, inputJSON input: Data) async throws -> String {
        switch name {
        case "list_targets": return try listTargets(args: Self.decodeArgs(input))
        case "get_target": return try getTarget(args: Self.decodeArgs(input))
        case "get_today_briefing": return try todayBriefing()
        case "list_digests": return try listDigests(args: Self.decodeArgs(input))
        case "get_digest": return try getDigest(args: Self.decodeArgs(input))
        case "list_tracks": return try listTracks(args: Self.decodeArgs(input))
        case "get_track": return try getTrack(args: Self.decodeArgs(input))
        case "list_people": return try listPeople(args: Self.decodeArgs(input))
        case "get_person": return try getPerson(args: Self.decodeArgs(input))
        case "list_upcoming_events": return try listUpcomingEvents(args: Self.decodeArgs(input))
        case "create_task": return try await createTask(args: Self.decodeArgs(input))
        case "snooze_item": return try await snoozeItem(args: Self.decodeArgs(input))
        default: throw ToolError("unknown tool \"\(name)\"")
        }
    }

    // MARK: - Targets

    private struct ListTargetsArgs: Decodable {
        var status: String?
        var priority: String?
        var level: String?
        var ownership: String?
        var limit: Int?
    }

    private struct GetByIDArgs: Decodable {
        var id: Int
    }

    private func listTargets(args: ListTargetsArgs) throws -> String {
        try Self.validate("status", args.status, oneOf: ["todo", "in_progress", "blocked", "done", "dismissed", "snoozed"])
        try Self.validate("priority", args.priority, oneOf: ["high", "medium", "low"])
        try Self.validate("level", args.level, oneOf: ["quarter", "month", "week", "day", "custom"])
        try Self.validate("ownership", args.ownership, oneOf: ["mine", "delegated", "watching"])
        // Go parity (GetTargets): done/dismissed are excluded unless the
        // caller filtered for them explicitly — without this, status=done
        // would always return [].
        let includeDone = args.status == "done" || args.status == "dismissed"
        let matches = try store.fetchAll(Target.self, kind: .target)
            .filter { target in
                if !includeDone, target.status == "done" || target.status == "dismissed" { return false }
                return Self.matches(target.status, args.status)
                    && Self.matches(target.priority, args.priority)
                    && Self.matches(target.level, args.level)
                    && Self.matches(target.ownership, args.ownership)
            }
            .sorted(by: Self.targetOrder)
            .prefix(Self.listLimit(args.limit))
        return Self.encode(.array(matches.map(Self.targetSummary)))
    }

    private func getTarget(args: GetByIDArgs) throws -> String {
        let target = try store.fetchAll(Target.self, kind: .target).first { $0.id == args.id }
        guard let target else { return "null" }
        return Self.encode(Self.targetDetail(target))
    }

    /// Go GetTargets ORDER BY: level rank, period_start ASC, priority rank,
    /// dated-before-undated, due_date ASC, created_at DESC (+ id tiebreaker
    /// for determinism — Swift's sort is not guaranteed stable).
    private static func targetOrder(_ a: Target, _ b: Target) -> Bool {
        if levelRank(a.level) != levelRank(b.level) { return levelRank(a.level) < levelRank(b.level) }
        if a.periodStart != b.periodStart { return a.periodStart < b.periodStart }
        if priorityRank(a.priority) != priorityRank(b.priority) {
            return priorityRank(a.priority) < priorityRank(b.priority)
        }
        if a.dueDate.isEmpty != b.dueDate.isEmpty { return b.dueDate.isEmpty }
        if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id < b.id
    }

    private static func levelRank(_ level: String) -> Int {
        switch level {
        case "quarter": 0
        case "month": 1
        case "week": 2
        case "day": 3
        default: 4
        }
    }

    /// Unknown priorities are unreachable (table CHECK constraint) — ranked
    /// last rather than mirroring SQLite's NULL-sorts-first artifact.
    private static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high": 0
        case "medium": 1
        case "low": 2
        default: 3
        }
    }

    private static func targetSummary(_ target: Target) -> WireJSON {
        [
            "id": .int(target.id),
            "text": .string(target.text),
            "status": .string(target.status),
            "priority": .string(target.priority),
            "level": .string(target.level),
            "ownership": .string(target.ownership),
            "due_date": .string(target.dueDate),
            "period_start": .string(target.periodStart),
            "period_end": .string(target.periodEnd),
            "progress": .double(target.progress)
        ]
    }

    private static func targetDetail(_ target: Target) -> WireJSON {
        merged(targetSummary(target), [
            "intent": .string(target.intent),
            "ball_on": .string(target.ballOn),
            "blocking": .string(target.blocking),
            "snooze_until": .string(target.snoozeUntil),
            "tags": parsedJSON(target.tags),
            "sub_items": parsedJSON(target.subItems),
            "notes": parsedJSON(target.notes),
            "source_type": .string(target.sourceType),
            "created_at": .string(target.createdAt),
            "updated_at": .string(target.updatedAt)
        ])
    }

    // MARK: - Briefing

    private func todayBriefing() throws -> String {
        // Go parity: time.Now().Format("2006-01-02") is the LOCAL date — the
        // injected instant rendered in the local calendar, never UTC (a 23:30
        // local briefing lookup must not roll over to tomorrow's UTC date).
        let today = Self.localDayString(now())
        let briefing = try store.fetchAll(Briefing.self, kind: .briefing)
            .filter { $0.date == today }
            .max { $0.id < $1.id }
        guard let briefing else { return "null" }
        return Self.encode(Self.briefingJSON(briefing))
    }

    private static func briefingJSON(_ briefing: Briefing) -> WireJSON {
        [
            "id": .int(briefing.id),
            "date": .string(briefing.date),
            "role": .string(briefing.role),
            "attention": parsedJSON(briefing.attention),
            "your_day": parsedJSON(briefing.yourDay),
            "what_happened": parsedJSON(briefing.whatHappened),
            "team_pulse": parsedJSON(briefing.teamPulse),
            "coaching": parsedJSON(briefing.coaching),
            "created_at": .string(briefing.createdAt)
        ]
    }

    // MARK: - Digests

    private struct ListDigestsArgs: Decodable {
        var type: String?
        var channel: String?
        var since: String?
        var limit: Int?
    }

    private func listDigests(args: ListDigestsArgs) throws -> String {
        try Self.validate("type", args.type, oneOf: ["channel", "daily", "weekly"])
        var sinceUnix: Double = 0
        if let since = args.since, !since.isEmpty {
            sinceUnix = try Self.parseSince(since).timeIntervalSince1970
        }
        let matches = try store.fetchAll(Digest.self, kind: .digest)
            .filter { digest in
                Self.matches(digest.type, args.type)
                    && Self.matchesSlackID(digest.channelID, args.channel)
                    && (sinceUnix <= 0 || digest.periodFrom >= sinceUnix)
            }
            .sorted(by: Self.digestOrder)
            .prefix(Self.listLimit(args.limit))
        return Self.encode(.array(matches.map(Self.digestSummary)))
    }

    private func getDigest(args: GetByIDArgs) throws -> String {
        let digest = try store.fetchAll(Digest.self, kind: .digest).first { $0.id == args.id }
        guard let digest else { return "null" }
        return Self.encode(Self.digestDetail(digest))
    }

    /// Go GetDigests ORDER BY period_to DESC, period_from DESC.
    private static func digestOrder(_ a: Digest, _ b: Digest) -> Bool {
        if a.periodTo != b.periodTo { return a.periodTo > b.periodTo }
        if a.periodFrom != b.periodFrom { return a.periodFrom > b.periodFrom }
        return a.id > b.id
    }

    private static func digestSummary(_ digest: Digest) -> WireJSON {
        [
            "id": .int(digest.id),
            "type": .string(digest.type),
            "channel_id": .string(digest.channelID),
            "period_from": unixISO(digest.periodFrom),
            "period_to": unixISO(digest.periodTo),
            "message_count": .int(digest.messageCount),
            "topics": parsedJSON(digest.topics),
            "created_at": .string(digest.createdAt)
        ]
    }

    private static func digestDetail(_ digest: Digest) -> WireJSON {
        // Owner decision (Task 4 review): action_items included — model-useful.
        // people_signals/situations/running_summary stay out as noise.
        merged(digestSummary(digest), [
            "summary": .string(digest.summary),
            "decisions": parsedJSON(digest.decisions),
            "action_items": parsedJSON(digest.tracksJSON)
        ])
    }

    // MARK: - Tracks

    private struct ListTracksArgs: Decodable {
        var priority: String?
        var ownership: String?
        var limit: Int?
    }

    private func listTracks(args: ListTracksArgs) throws -> String {
        try Self.validate("priority", args.priority, oneOf: ["high", "medium", "low"])
        try Self.validate("ownership", args.ownership, oneOf: ["mine", "delegated", "watching"])
        // Go parity (GetTracks): active by default — dismissed excluded.
        let matches = try store.fetchAll(Track.self, kind: .track)
            .filter { track in
                track.dismissedAt.isEmpty
                    && Self.matches(track.priority, args.priority)
                    && Self.matches(track.ownership, args.ownership)
            }
            .sorted(by: Self.trackOrder)
            .prefix(Self.listLimit(args.limit))
        return Self.encode(.array(matches.map(Self.trackSummary)))
    }

    private func getTrack(args: GetByIDArgs) throws -> String {
        let track = try store.fetchAll(Track.self, kind: .track).first { $0.id == args.id }
        guard let track else { return "null" }
        return Self.encode(Self.trackDetail(track))
    }

    /// Go GetTracks ORDER BY has_updates DESC, updated_at DESC.
    private static func trackOrder(_ a: Track, _ b: Track) -> Bool {
        if a.hasUpdates != b.hasUpdates { return a.hasUpdates }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    private static func trackSummary(_ track: Track) -> WireJSON {
        [
            "id": .int(track.id),
            "text": .string(track.text),
            "category": .string(track.category),
            "priority": .string(track.priority),
            "ownership": .string(track.ownership),
            "ball_on": .string(track.ballOn),
            "has_updates": .bool(track.hasUpdates),
            "due_date": unixISO(track.dueDate ?? 0),
            "created_at": .string(track.createdAt),
            "updated_at": .string(track.updatedAt)
        ]
    }

    private static func trackDetail(_ track: Track) -> WireJSON {
        merged(trackSummary(track), [
            "context": .string(track.context),
            "blocking": .string(track.blocking),
            "requester_name": .string(track.requesterName),
            "decision_summary": .string(track.decisionSummary),
            "decision_options": parsedJSON(track.decisionOptions),
            "sub_items": parsedJSON(track.subItems),
            "participants": parsedJSON(track.participants),
            "tags": parsedJSON(track.tags),
            "linked_target_id": track.linkedTargetID.flatMap { $0 > 0 ? .int($0) : nil } ?? .null
        ])
    }

    // MARK: - People

    private struct ListPeopleArgs: Decodable {
        var limit: Int?
    }

    private struct GetPersonArgs: Decodable {
        var query: String
    }

    private func listPeople(args: ListPeopleArgs) throws -> String {
        let matches = try store.fetchAll(PeopleCard.self, kind: .personCard)
            .sorted(by: Self.personOrder)
            .prefix(Self.listLimit(args.limit))
        return Self.encode(.array(matches.map(Self.personSummary)))
    }

    private func getPerson(args: GetPersonArgs) throws -> String {
        // An empty query is a miss, not `matchesSlackID`'s "no filter" — that
        // is list-tool semantics and here it would hand back a random card.
        guard !args.query.isEmpty else { return "null" }
        // Slack user-id match only. The Go tool falls back to
        // SearchUsersByName, but the users table is not a replica slice —
        // name lookup is a documented phone-side gap, and an unmatched query
        // is null (MCP mirror rule), not an error.
        //
        // A bare raw id can match cards from several accounts; the newest wins.
        let card = try store.fetchAll(PeopleCard.self, kind: .personCard)
            .filter { Self.matchesSlackID($0.userID, args.query) }
            .min(by: Self.personOrder)
        guard let card else { return "null" }
        return Self.encode(Self.personDetail(card))
    }

    /// Go GetPeopleCards ORDER BY period_to DESC, period_from DESC; the same
    /// comparator's minimum is GetLatestPeopleCard's "most recent card".
    private static func personOrder(_ a: PeopleCard, _ b: PeopleCard) -> Bool {
        if a.periodTo != b.periodTo { return a.periodTo > b.periodTo }
        if a.periodFrom != b.periodFrom { return a.periodFrom > b.periodFrom }
        return a.id > b.id
    }

    private static func personSummary(_ card: PeopleCard) -> WireJSON {
        [
            "id": .int(Int(card.id)),
            "user_id": .string(card.userID),
            "summary": .string(card.summary),
            "communication_style": .string(card.communicationStyle),
            "decision_role": .string(card.decisionRole),
            "message_count": .int(card.messageCount),
            "period_from": unixISO(card.periodFrom),
            "period_to": unixISO(card.periodTo)
        ]
    }

    private static func personDetail(_ card: PeopleCard) -> WireJSON {
        merged(personSummary(card), [
            "red_flags": parsedJSON(card.redFlags),
            "highlights": parsedJSON(card.highlights),
            "accomplishments": parsedJSON(card.accomplishments),
            "communication_guide": .string(card.communicationGuide),
            "decision_style": .string(card.decisionStyle),
            "tactics": parsedJSON(card.tactics),
            "relationship_context": .string(card.relationshipContext),
            "status": .string(card.status)
        ])
    }

    // MARK: - Calendar events

    private struct ListEventsArgs: Decodable {
        var hours: Int?
        var limit: Int?
    }

    private func listUpcomingEvents(args: ListEventsArgs) throws -> String {
        var hours = args.hours ?? 48
        if hours <= 0 { hours = 48 }
        let start = now()
        // Go parity (GetCalendarEvents): end_time >= now AND start_time <=
        // now+hours, compared as ISO8601 UTC STRINGS the way SQLite does —
        // an event already in progress counts as upcoming.
        let from = Self.isoUTC.string(from: start)
        let to = Self.isoUTC.string(from: start.addingTimeInterval(TimeInterval(hours) * 3_600))
        let matches = try store.fetchAll(CalendarEvent.self, kind: .calendarEvent)
            .filter { $0.endTime >= from && $0.startTime <= to }
            .sorted(by: Self.eventOrder)
            .prefix(Self.listLimit(args.limit))
        return Self.encode(.array(matches.map(Self.eventJSON)))
    }

    /// Go GetCalendarEvents ORDER BY start_time (ascending).
    private static func eventOrder(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        a.startTime != b.startTime ? a.startTime < b.startTime : a.id < b.id
    }

    private static func eventJSON(_ event: CalendarEvent) -> WireJSON {
        [
            "id": .string(event.id),
            "title": .string(event.title),
            "start_time": .string(event.startTime),
            "end_time": .string(event.endTime),
            "location": .string(event.location),
            "is_all_day": .bool(event.isAllDay),
            "event_status": .string(event.eventStatus),
            "organizer_email": .string(event.organizerEmail),
            "attendees": .array(event.parsedAttendees.map { attendee in
                [
                    "email": .string(attendee.email),
                    "display_name": .string(attendee.displayName),
                    "response_status": .string(attendee.responseStatus)
                ]
            })
        ]
    }

    // MARK: - Write tools (queue through ActionOutbox)

    private struct CreateTaskArgs: Decodable {
        var text: String?
    }

    private struct SnoozeItemArgs: Decodable {
        var entityType: String?
        var id: Int?
        var until: String?

        enum CodingKeys: String, CodingKey {
            case entityType = "entity_type"
            case id
            case until
        }
    }

    /// The fixed reply of both write tools. Matches `encode`'s sortedKeys
    /// rendering of {status, note}.
    private static let queuedJSON =
        #"{"note":"will apply when your Mac processes the queue","status":"queued"}"#

    private func createTask(args: CreateTaskArgs) async throws -> String {
        let text = (args.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("text is required") }
        _ = try await outbox.enqueue(kind: .taskCreate, entityRecordName: nil, params: ["text": .string(text)])
        return Self.queuedJSON
    }

    private func snoozeItem(args: SnoozeItemArgs) async throws -> String {
        let kind: ActionKind
        let sliceKind: SliceKind
        switch args.entityType {
        case "target":
            kind = .targetSnooze
            sliceKind = .target
        case "inbox_item":
            kind = .inboxSnooze
            sliceKind = .inboxItem
        default:
            throw ToolError("invalid entity_type \"\(args.entityType ?? "")\": must be one of target|inbox_item")
        }
        guard let id = args.id else { throw ToolError("id is required") }
        let raw = args.until ?? ""
        guard let until = Self.isoUTC.date(from: raw) ?? Self.isoFractional.date(from: raw) else {
            throw ToolError("invalid until \"\(raw)\": use ISO8601, e.g. 2026-07-10T00:00:00Z")
        }
        _ = try await outbox.enqueue(
            kind: kind,
            entityRecordName: sliceKind.recordName(id: String(id)),
            params: ActionOutbox.snoozeParams(until: until)
        )
        return Self.queuedJSON
    }

    // MARK: - Shared plumbing

    /// Input-validation failure surfaced to the model as `{"error": ...}`.
    private struct ToolError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private static func decodeArgs<Args: Decodable>(_ data: Data) throws -> Args {
        // Models may omit the input entirely for no-arg tools.
        let json = data.isEmpty ? Data("{}".utf8) : data
        do {
            return try JSONDecoder().decode(Args.self, from: json)
        } catch {
            throw ToolError("invalid tool input: \(error.localizedDescription)")
        }
    }

    /// Mirrors the Go `validateEnum`: empty/absent means "no filter".
    private static func validate(_ field: String, _ value: String?, oneOf allowed: [String]) throws {
        guard let value, !value.isEmpty, !allowed.contains(value) else { return }
        throw ToolError("invalid \(field) \"\(value)\": must be one of \(allowed.joined(separator: "|"))")
    }

    /// Mirrors the Go `listLimit`: unset/0 → 50, capped at 200.
    private static func listLimit(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return 50 }
        return min(requested, 200)
    }

    private static func matches(_ value: String, _ filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return value == filter
    }

    /// `matches` for a stored account-namespaced Slack id (`"1:U0456"`), which
    /// also answers a bare raw query. A namespaced query is NEVER stripped —
    /// `"2:U0456"` must not reach account 1's row — so widening only ever adds
    /// matches, never crosses accounts. Precondition: the column holds Slack
    /// ids only; `inbox_items.channel_id` is heterogeneous (Jira keys,
    /// calendar event ids, the literal `"briefing"`, `gmail:`/`imap:`
    /// prefixes), so extending this helper there is a deliberate decision, not
    /// an assumption.
    private static func matchesSlackID(_ value: String, _ filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        if value == filter { return true }
        return !SlackID.split(filter).isNamespaced && SlackID.split(value).rawID == filter
    }

    /// Go `parseSince`: a date (YYYY-MM-DD, LOCAL midnight) or an RFC3339
    /// timestamp.
    private static func parseSince(_ raw: String) throws -> Date {
        if raw.count == 10 {
            let parts = raw.split(separator: "-")
            if parts.count == 3,
               let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
               let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) {
                return date
            }
        }
        if let date = isoUTC.date(from: raw) ?? isoFractional.date(from: raw) {
            return date
        }
        throw ToolError("invalid since \"\(raw)\": use YYYY-MM-DD or RFC3339")
    }

    /// The injected instant rendered as the user's LOCAL calendar day.
    private static func localDayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Thread-safe per Apple's docs; plain internet-date-time UTC, matching
    /// Go's `time.RFC3339` rendering of UTC instants.
    private static let isoUTC = ISO8601DateFormatter()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Unix seconds → ISO8601 UTC; 0/absent → null (Go's "no deadline").
    private static func unixISO(_ seconds: Double) -> WireJSON {
        guard seconds > 0 else { return .null }
        return .string(isoUTC.string(from: Date(timeIntervalSince1970: seconds)))
    }

    /// Re-parses a JSON string column (tags, sub_items, notes, …) so tool
    /// output carries structured JSON instead of embedded strings. Empty or
    /// unparseable → [] (the columns are all arrays by contract).
    private static func parsedJSON(_ raw: String) -> WireJSON {
        guard !raw.isEmpty,
              let value = try? JSONDecoder().decode(WireJSON.self, from: Data(raw.utf8)) else {
            return .array([])
        }
        return value
    }

    private static func merged(_ base: WireJSON, _ extra: [String: WireJSON]) -> WireJSON {
        guard case .object(var dict) = base else { return base }
        for (key, value) in extra { dict[key] = value }
        return .object(dict)
    }

    private static func encode(_ value: WireJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            // Unreachable: WireJSON always encodes. Kept as a safe reply
            // rather than a trap because execute must never throw.
            return #"{"error":"failed to encode tool result"}"#
        }
        return json
    }

    private static func errorJSON(_ message: String) -> String {
        encode(["error": .string(message)])
    }
}

// MARK: - Tool definitions

extension ReplicaToolbox {
    private static let limitProperty: WireJSON = [
        "type": "integer",
        "description": "max results, 0 = default (50), capped at 200"
    ]

    private static let listTargetsTool = APITool(
        name: "list_targets",
        description: "List the user's personal action items (targets), optionally filtered by status, priority, level, or ownership.",
        inputSchema: [
            "type": "object",
            "properties": [
                "status": [
                    "type": "string",
                    "description": "filter by status: todo|in_progress|blocked|done|dismissed|snoozed"
                ],
                "priority": ["type": "string", "description": "filter by priority: high|medium|low"],
                "level": ["type": "string", "description": "filter by level: quarter|month|week|day|custom"],
                "ownership": ["type": "string", "description": "filter by ownership: mine|delegated|watching"],
                "limit": limitProperty
            ]
        ]
    )

    private static let getTargetTool = APITool(
        name: "get_target",
        description: "Get a single target by id, including sub-items, notes, and metadata.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "integer", "description": "target id"]],
            "required": ["id"]
        ]
    )

    private static let todayBriefingTool = APITool(
        name: "get_today_briefing",
        description: "Get today's daily briefing (your personalized roll-up of what needs attention). "
            + "Returns null if today's briefing hasn't been generated yet.",
        inputSchema: ["type": "object", "properties": [:]]
    )

    private static let listDigestsTool = APITool(
        name: "list_digests",
        description: "List channel/daily/weekly digests (AI summaries of Slack activity), most recent first.",
        inputSchema: [
            "type": "object",
            "properties": [
                "type": ["type": "string", "description": "digest type: channel|daily|weekly"],
                "channel": [
                    "type": "string",
                    "description": "channel id: namespaced \"<account>:C…\" as returned, or a bare \"C…\" (matches every account)"
                ],
                "since": [
                    "type": "string",
                    "description": "only digests whose period starts on/after this date (YYYY-MM-DD or RFC3339)"
                ],
                "limit": limitProperty
            ]
        ]
    )

    private static let getDigestTool = APITool(
        name: "get_digest",
        description: "Get a single digest by id, including its full summary.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "integer", "description": "digest id"]],
            "required": ["id"]
        ]
    )

    private static let listTracksTool = APITool(
        name: "list_tracks",
        description: "List work/narrative tracks (active by default), optionally filtered by priority or ownership.",
        inputSchema: [
            "type": "object",
            "properties": [
                "priority": ["type": "string", "description": "filter by priority: high|medium|low"],
                "ownership": ["type": "string", "description": "filter by ownership: mine|delegated|watching"],
                "limit": limitProperty
            ]
        ]
    )

    private static let getTrackTool = APITool(
        name: "get_track",
        description: "Get a single track by id.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "integer", "description": "track id"]],
            "required": ["id"]
        ]
    )

    private static let listPeopleTool = APITool(
        name: "list_people",
        description: "List people cards (per-person communication and collaboration profiles).",
        inputSchema: [
            "type": "object",
            "properties": ["limit": limitProperty]
        ]
    )

    private static let getPersonTool = APITool(
        name: "get_person",
        description: "Get the latest people card for a person by Slack user id, namespaced \"<account>:U…\" "
            + "as other tools return it (a bare \"U…\" also matches, newest card across accounts). "
            + "Name search is not available on the phone.",
        inputSchema: [
            "type": "object",
            "properties": ["query": [
                "type": "string",
                "description": "Slack user id: \"<account>:U…\" (e.g. 1:U0456), or a bare \"U…\""
            ]],
            "required": ["query"]
        ]
    )

    private static let listUpcomingEventsTool = APITool(
        name: "list_upcoming_events",
        description: "List calendar events in the next N hours (default 48).",
        inputSchema: [
            "type": "object",
            "properties": [
                "hours": ["type": "integer", "description": "look-ahead window in hours, default 48"],
                "limit": limitProperty
            ]
        ]
    )

    private static let createTaskTool = APITool(
        name: "create_task",
        description: "Create a new task (target) with the given text. The task is queued on the phone and applies when your Mac processes the queue.",
        inputSchema: [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "the task text"]],
            "required": ["text"]
        ]
    )

    private static let snoozeItemTool = APITool(
        name: "snooze_item",
        description: "Snooze a target or inbox item until a date/time (queued; applies when your Mac processes the queue). "
            + "IMPORTANT: target snoozes are day-granularity on the desktop — it truncates the timestamp "
            + "to a calendar day in the MAC'S local time zone, so pass noon of the intended LOCAL day "
            + "(a UTC midnight lands on the previous day west of UTC); sub-day snoozes only make sense for inbox items.",
        inputSchema: [
            "type": "object",
            "properties": [
                "entity_type": ["type": "string", "description": "what to snooze: target|inbox_item"],
                "id": ["type": "integer", "description": "the target or inbox item id"],
                "until": ["type": "string", "description": "snooze until, ISO8601 (e.g. 2026-07-10T12:00:00Z for the July 10 local day)"]
            ],
            "required": ["entity_type", "id", "until"]
        ]
    )

    private static let toolDefinitions: [APITool] = [
        listTargetsTool, getTargetTool,
        todayBriefingTool, listDigestsTool, getDigestTool,
        listTracksTool, getTrackTool,
        listPeopleTool, getPersonTool,
        listUpcomingEventsTool,
        createTaskTool, snoozeItemTool
    ]
}
