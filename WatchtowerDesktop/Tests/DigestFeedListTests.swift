import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Coverage for `DigestFeedList` — the Digests feed's search matching, day
/// bucketing, and day-header labeling, extracted out of `DigestListView` so
/// it can be exercised without instantiating the view.
///
/// Dates: the grouping cases are seeded from a fixed reference instant (they
/// never compare against "now", so they cannot go stale), and the labeling
/// cases — which *do* read the system clock through `Calendar.isDateInToday`
/// — are seeded relative to `Date()`. A UTC calendar and a POSIX locale are
/// injected everywhere so the assertions hold in any machine timezone.
final class DigestFeedListTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    /// `DigestViewModel.load()` only feeds recapped recordings into the feed.
    private let recapJSON = #"{"summary":"s","key_decisions":[],"action_items":[],"open_questions":[]}"#

    private var utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private let posix = Locale(identifier: "en_US_POSIX")

    /// 2026-01-15T00:00:00Z — a fixed instant, not wall-clock-relative.
    private let reference = Date(timeIntervalSince1970: 1_768_435_200)

    private func iso(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone(identifier: "UTC")!
        return fmt.string(from: date)
    }

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    private func loadedEntries() -> [DigestFeedEntry] {
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        return vm.feedEntries
    }

    private func entry(_ entries: [DigestFeedEntry], matching kind: String) -> DigestFeedEntry {
        entries.first { $0.id.hasPrefix(kind) }!
    }

    // MARK: - matches: cross-source search

    /// One query per searched field, across all three sources — the fields
    /// each case actually surfaces in its row.
    @MainActor
    func testMatchesSearchesEverySourcesOwnFields() throws {
        let streamTopics = #"[{"title":"Vendor renewal","summary":"contract expires in March"}]"#
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(
                db, summary: "Quarterly planning wrapped up",
                topics: #"["Roadmap"]"#)
            _ = try TestDatabase.insertStreamDigest(
                db, scope: "billing@corp.com", topicsJSON: streamTopics)
            try TestDatabase.insertMeetingTranscript(
                db, eventID: nil, title: "Standup recording",
                transcriptText: "we walked through the migration",
                summaryJSON: recapJSON)
        }

        let entries = loadedEntries()
        let slack = entry(entries, matching: "slack")
        let stream = entry(entries, matching: "stream")
        let meeting = entry(entries, matching: "meeting")
        let noChannel: (Digest) -> String? = { _ in nil }

        // .slack — summary and topics.
        XCTAssertTrue(DigestFeedList.matches(slack, query: "quarterly", channelName: noChannel))
        XCTAssertTrue(DigestFeedList.matches(slack, query: "roadmap", channelName: noChannel))
        XCTAssertFalse(DigestFeedList.matches(slack, query: "vendor", channelName: noChannel))

        // .slack — channel name, resolved through the injected closure only.
        XCTAssertFalse(DigestFeedList.matches(slack, query: "engineering", channelName: noChannel))
        XCTAssertTrue(DigestFeedList.matches(slack, query: "engineering") { _ in "Engineering" })

        // .stream — scope, topic title, topic summary.
        XCTAssertTrue(DigestFeedList.matches(stream, query: "billing", channelName: noChannel))
        XCTAssertTrue(DigestFeedList.matches(stream, query: "vendor renewal", channelName: noChannel))
        XCTAssertTrue(DigestFeedList.matches(stream, query: "contract expires", channelName: noChannel))
        XCTAssertFalse(DigestFeedList.matches(stream, query: "quarterly", channelName: noChannel))

        // .meeting — title and transcript snippet.
        XCTAssertTrue(DigestFeedList.matches(meeting, query: "standup", channelName: noChannel))
        XCTAssertTrue(DigestFeedList.matches(meeting, query: "migration", channelName: noChannel))
        XCTAssertFalse(DigestFeedList.matches(meeting, query: "billing", channelName: noChannel))

        // A query nothing carries matches nothing.
        for e in entries {
            XCTAssertFalse(
                DigestFeedList.matches(e, query: "zzzznotpresent", channelName: noChannel),
                "unexpected match for \(e.id)")
        }
    }

    /// A meeting also matches on its linked calendar event's title, which is
    /// what the row displays when present.
    @MainActor
    func testMatchesMeetingOnLinkedEventTitle() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1", title: "Budget review")
            try TestDatabase.insertMeetingTranscript(
                db, eventID: "evt-1", title: "Rec",
                transcriptText: "text", summaryJSON: recapJSON)
        }

        let meeting = entry(loadedEntries(), matching: "meeting")
        XCTAssertTrue(DigestFeedList.matches(meeting, query: "budget") { _ in nil })
    }

    // MARK: - group: day bucketing

    /// Buckets by day, keeps encounter order for both the sections and the
    /// entries inside them, and puts an entry landing exactly on midnight in
    /// that new day rather than the previous one.
    @MainActor
    func testGroupBucketsByDayPreservingEncounterOrderAcrossMidnight() throws {
        // day 2 midnight exactly, one second before it, and day 2 midday.
        let midnight = reference.addingTimeInterval(86_400)
        let justBefore = midnight.addingTimeInterval(-1)
        let midday = midnight.addingTimeInterval(43_200)

        try dbManager.dbPool.write { db in
            // Distinct channels: `digests` is unique on
            // (channel_id, type, period_from, period_to).
            try TestDatabase.insertDigest(db, channelID: "C1", summary: "midnight", createdAt: iso(midnight))
            try TestDatabase.insertDigest(db, channelID: "C2", summary: "before", createdAt: iso(justBefore))
            try TestDatabase.insertDigest(db, channelID: "C3", summary: "midday", createdAt: iso(midday))
        }

        // Newest first (the VM's default sort): midday, midnight, before.
        let sections = DigestFeedList.group(loadedEntries(), calendar: utc)

        XCTAssertEqual(sections.count, 2, "two calendar days, got \(sections.map(\.day))")
        XCTAssertEqual(sections[0].day, utc.startOfDay(for: midday))
        XCTAssertEqual(sections[0].entries.count, 2, "midday + midnight share day 2")
        XCTAssertEqual(sections[1].day, utc.startOfDay(for: justBefore))
        XCTAssertEqual(sections[1].entries.count, 1)

        // Encounter order inside a section is preserved (midday before midnight).
        guard case .slack(let first) = sections[0].entries[0],
              case .slack(let second) = sections[0].entries[1],
              case .slack(let lone) = sections[1].entries[0] else {
            return XCTFail("expected slack entries")
        }
        XCTAssertEqual(first.summary, "midday")
        XCTAssertEqual(second.summary, "midnight")
        XCTAssertEqual(lone.summary, "before")

        // The section id is the day itself (ForEach(id: \.day) in the view).
        XCTAssertEqual(sections[0].id, sections[0].day)
    }

    func testGroupOfNothingIsNoSections() {
        XCTAssertTrue(DigestFeedList.group([], calendar: utc).isEmpty)
    }

    /// The same instants bucket differently under a different timezone —
    /// pinning that grouping follows the injected calendar, not UTC.
    @MainActor
    func testGroupFollowsTheInjectedCalendarsTimeZone() throws {
        let midnightUTC = reference.addingTimeInterval(86_400)
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C1", summary: "a", createdAt: iso(midnightUTC))
            try TestDatabase.insertDigest(
                db, channelID: "C2", summary: "b",
                createdAt: iso(midnightUTC.addingTimeInterval(-3_600)))
        }
        let entries = loadedEntries()

        XCTAssertEqual(DigestFeedList.group(entries, calendar: utc).count, 2)

        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 00:00Z and 23:00Z are 01:00 and 00:00 Berlin — the same local day.
        XCTAssertEqual(DigestFeedList.group(entries, calendar: berlin).count, 1)
    }

    // MARK: - dayLabel

    /// Clock-relative by nature (`isDateInToday`), so seeded from `Date()`.
    func testDayLabelNamesTodayAndYesterday() {
        let now = Date()
        XCTAssertEqual(DigestFeedList.dayLabel(for: now, calendar: .current, locale: posix), "Today")
        XCTAssertEqual(
            DigestFeedList.dayLabel(
                for: Calendar.current.date(byAdding: .day, value: -1, to: now)!,
                calendar: .current, locale: posix),
            "Yesterday")
    }

    func testDayLabelFallsBackToWeekdayAndDate() {
        let older = Calendar.current.date(byAdding: .day, value: -10, to: Date())!

        let expected = DateFormatter()
        expected.locale = posix
        expected.timeZone = Calendar.current.timeZone
        expected.dateFormat = "EEEE, d MMM"

        XCTAssertEqual(
            DigestFeedList.dayLabel(for: older, calendar: .current, locale: posix),
            expected.string(from: older))
    }

    /// Tomorrow is not special-cased (unlike `MeetingListBuilder`, whose list
    /// is forward-looking) — the feed only ever shows material already
    /// produced, so a future day falls through to the dated label.
    func testDayLabelDoesNotSpecialCaseTomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let label = DigestFeedList.dayLabel(for: tomorrow, calendar: .current, locale: posix)
        XCTAssertNotEqual(label, "Tomorrow")
        XCTAssertTrue(label.contains(","), "expected the dated fallback, got \(label)")
    }
}
