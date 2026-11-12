import XCTest
import GRDB
@testable import WatchtowerCore

/// The Idea finder's daily batch: selection, the per-day store, counts and copy.
final class IdeaDailyBatchTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    /// Injected clock and zone: every date below is relative to `now`. Both
    /// are fixed in `setUpWithError` and never fall back to the wall clock.
    private var now: Date!
    private var calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        try super.setUpWithError()
        now = try XCTUnwrap(AutomationDates.parse("2026-11-12T10:00:00Z"))
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        suite = "IdeaDailyBatchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func stamp(daysAgo: Double, hours: Double = 0) -> String {
        AutomationDates.format(now.addingTimeInterval(-(daysAgo * 86400 + hours * 3600)))
    }

    private func idea(
        _ id: Int,
        daysAgo: Double,
        kind: String = "idea",
        status: String = "proposed",
        chatBorn: Bool = false,
        updatedAt: String? = nil,
        createdAt: String? = nil,
        title: String? = nil
    ) -> Idea {
        Idea(row: Row([
            "id": id, "kind": kind, "title": title ?? "Idea \(id)", "essence": "e", "status": status,
            "created_at": createdAt ?? stamp(daysAgo: daysAgo),
            "updated_at": updatedAt ?? stamp(daysAgo: daysAgo),
            "chat_born": chatBorn
        ] as [String: (any DatabaseValueConvertible)?]))
    }

    /// `count` proposed ideas, id 1 the oldest (created `count` hours ago).
    private func fresh(_ count: Int, from first: Int = 1) -> [Idea] {
        (0..<count).map { idea(first + $0, daysAgo: 0, createdAt: stamp(daysAgo: 1, hours: Double(count - $0))) }
    }

    private func judged(_ ideas: [Idea], ids: Set<Int>, status: String, updatedAt: String) -> [Idea] {
        ideas.map { item in
            guard ids.contains(item.id) else { return item }
            return idea(item.id, daysAgo: 0, status: status, updatedAt: updatedAt, createdAt: item.createdAt)
        }
    }

    // MARK: - Selection

    func testCandidatesOldestFirstWithinThirtyDays() {
        let ideas = [
            idea(1, daysAgo: 2),
            idea(2, daysAgo: 10),
            idea(3, daysAgo: 31),                                  // older than 30 days
            idea(4, daysAgo: 5, kind: "decision"),                 // a decision never waits
            idea(5, daysAgo: 6, kind: "decision", chatBorn: true), // chat-born decision waits
            idea(6, daysAgo: 3, status: "active"),                 // already judged
            idea(7, daysAgo: 10),                                  // same created_at as 2 → id order
            idea(8, daysAgo: 1, createdAt: "not a date")           // unparseable
        ]
        XCTAssertEqual(IdeaDailyBatch.candidates(ideas, now: now).map(\.id), [2, 7, 5, 1])
        XCTAssertTrue(IdeaDailyBatch.isOld(ideas[2], now: now))
        XCTAssertFalse(IdeaDailyBatch.isOld(ideas[0], now: now))
        XCTAssertFalse(IdeaDailyBatch.isOld(ideas[7], now: now))
        XCTAssertFalse(IdeaDailyBatch.isOld(idea(9, daysAgo: 40, status: "active"), now: now))
    }

    func testFirstReadOfDayStoresBatch() {
        let ideas = fresh(20)
        let state = IdeaDailyBatch(defaults: defaults).today(ideas: ideas, now: now, calendar: calendar)
        XCTAssertEqual(defaults.string(forKey: IdeaDailyBatch.dateKey), "2026-11-12")
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], Array(1...13))
        XCTAssertEqual(state.batchIDs, Array(1...13))
        XCTAssertEqual(state.remaining.map(\.id), Array(1...13))
        XCTAssertEqual(state.size, 13)
        XCTAssertEqual(state.judgedCount, 0)
        XCTAssertEqual(state.backlogCount, 7)
    }

    func testLaterReadKeepsStoredIDsAndDropsJudged() {
        let batch = IdeaDailyBatch(defaults: defaults)
        var ideas = fresh(20)
        _ = batch.today(ideas: ideas, now: now, calendar: calendar)
        ideas = judged(ideas, ids: [2], status: "rejected", updatedAt: stamp(daysAgo: 0))
        ideas.append(idea(99, daysAgo: 20)) // older than every batch idea, arrives later
        let state = batch.today(ideas: ideas, now: now.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(state.batchIDs, Array(1...13))
        XCTAssertEqual(state.remaining.map(\.id), [1] + Array(3...13))
        XCTAssertEqual(state.judgedCount, 1)
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], Array(1...13))
    }

    func testNewDayRepicks() {
        let batch = IdeaDailyBatch(defaults: defaults)
        var ideas = fresh(20)
        _ = batch.today(ideas: ideas, now: now, calendar: calendar)
        ideas = judged(ideas, ids: [1, 2, 3], status: "rejected", updatedAt: stamp(daysAgo: 0))
        let tomorrow = now.addingTimeInterval(86400)
        let state = batch.today(ideas: ideas, now: tomorrow, calendar: calendar)
        XCTAssertEqual(defaults.string(forKey: IdeaDailyBatch.dateKey), "2026-11-13")
        XCTAssertEqual(state.batchIDs, Array(4...16))
        XCTAssertEqual(state.judgedCount, 0)
    }

    func testEmptyStoredBatchIsRepicked() {
        defaults.set("2026-11-12", forKey: IdeaDailyBatch.dateKey)
        defaults.set([Int](), forKey: IdeaDailyBatch.idsKey)
        let state = IdeaDailyBatch(defaults: defaults).today(ideas: fresh(3), now: now, calendar: calendar)
        XCTAssertEqual(state.batchIDs, [1, 2, 3])
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], [1, 2, 3])
    }

    func testCorruptStoredIDsRepick() {
        defaults.set("2026-11-12", forKey: IdeaDailyBatch.dateKey)
        defaults.set("1,2,3", forKey: IdeaDailyBatch.idsKey)
        let state = IdeaDailyBatch(defaults: defaults).today(ideas: fresh(2), now: now, calendar: calendar)
        XCTAssertEqual(state.batchIDs, [1, 2])
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], [1, 2])
    }

    func testSizeFromDefaults() {
        let batch = IdeaDailyBatch(defaults: defaults)
        XCTAssertEqual(batch.size, 13)
        let bads: [Any] = [0, -3, "x"]
        for bad in bads {
            defaults.set(bad, forKey: IdeaDailyBatch.sizeKey)
            XCTAssertEqual(batch.size, 13, "\(bad)")
        }
        defaults.set(5, forKey: IdeaDailyBatch.sizeKey)
        XCTAssertEqual(batch.size, 5)
        XCTAssertEqual(batch.today(ideas: fresh(8), now: now, calendar: calendar).batchIDs, Array(1...5))
    }

    func testNextReplacesTheBatch() {
        let batch = IdeaDailyBatch(defaults: defaults)
        var ideas = fresh(30)
        _ = batch.today(ideas: ideas, now: now, calendar: calendar)
        let laterToday = stamp(daysAgo: 0, hours: 1)
        ideas = judged(ideas, ids: [1, 2], status: "active", updatedAt: laterToday)
        ideas = judged(ideas, ids: Set(3...13), status: "rejected", updatedAt: laterToday)
        let done = batch.today(ideas: ideas, now: now, calendar: calendar)
        XCTAssertEqual(done.judgedCount, 13)
        XCTAssertEqual(done.nextAvailable, 13)

        let state = batch.next(ideas: ideas, now: now, calendar: calendar)
        XCTAssertEqual(state.batchIDs, Array(14...26))
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], Array(14...26))
        XCTAssertEqual(defaults.string(forKey: IdeaDailyBatch.dateKey), "2026-11-12")
        XCTAssertEqual(state.judgedCount, 0)
        XCTAssertEqual(Set(state.keptToday.map(\.id)), [1, 2])
        XCTAssertEqual(batch.today(ideas: ideas, now: now, calendar: calendar).batchIDs, Array(14...26))
    }

    func testNextPutsUnjudgedLeftoversFirst() {
        let batch = IdeaDailyBatch(defaults: defaults)
        var ideas = fresh(30)
        _ = batch.today(ideas: ideas, now: now, calendar: calendar)
        ideas = judged(ideas, ids: Set(1...10), status: "rejected", updatedAt: stamp(daysAgo: 0))
        let state = batch.next(ideas: ideas, now: now, calendar: calendar)
        XCTAssertEqual(state.batchIDs, Array(11...23))
    }

    func testStoredIDOfDeletedIdeaIsJudged() {
        defaults.set("2026-11-12", forKey: IdeaDailyBatch.dateKey)
        defaults.set([1, 2, 42], forKey: IdeaDailyBatch.idsKey)
        let state = IdeaDailyBatch(defaults: defaults).today(ideas: fresh(2), now: now, calendar: calendar)
        XCTAssertEqual(state.batchIDs, [1, 2, 42])
        XCTAssertEqual(state.remaining.map(\.id), [1, 2])
        XCTAssertEqual(state.judgedCount, 1)
    }

    /// Kept today = the ideas handed out today, across every Next, that are
    /// now active: an active idea outside today's batches is absent even
    /// when its `updated_at` is today (a new mention bumps it), and
    /// yesterday's batches do not count.
    func testKeptTodaySpansBatchesAndExcludesYesterday() {
        let batch = IdeaDailyBatch(defaults: defaults)
        // Yesterday's batch, one of it kept yesterday.
        var ideas = fresh(40)
        _ = batch.today(ideas: ideas, now: now.addingTimeInterval(-86400), calendar: calendar)
        ideas = judged(ideas, ids: [1], status: "active", updatedAt: stamp(daysAgo: 1))
        ideas = judged(ideas, ids: Set(2...13), status: "rejected", updatedAt: stamp(daysAgo: 1))

        _ = batch.today(ideas: ideas, now: now, calendar: calendar)
        ideas = judged(ideas, ids: [14], status: "active", updatedAt: stamp(daysAgo: 0, hours: 3))
        ideas = judged(ideas, ids: Set(15...26), status: "rejected", updatedAt: stamp(daysAgo: 0, hours: 3))
        _ = batch.next(ideas: ideas, now: now, calendar: calendar)
        ideas = judged(ideas, ids: [27], status: "active", updatedAt: stamp(daysAgo: 0, hours: 1))
        // Active and touched today, never in today's batches.
        ideas.append(idea(50, daysAgo: 4, status: "active", updatedAt: stamp(daysAgo: 0)))
        ideas = judged(ideas, ids: [1], status: "active", updatedAt: stamp(daysAgo: 0))
        let state = batch.today(ideas: ideas, now: now, calendar: calendar)
        XCTAssertEqual(state.keptToday.map(\.id), [27, 14])
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.dayIDsKey) as? [Int], Array(14...39))
    }

    func testBacklogAndOlderCounts() {
        defaults.set(2, forKey: IdeaDailyBatch.sizeKey)
        let ideas = fresh(4) + [
            idea(10, daysAgo: 40),
            idea(11, daysAgo: 35),
            idea(12, daysAgo: 50, status: "active"),
            idea(13, daysAgo: 45, kind: "decision")
        ]
        let state = IdeaDailyBatch(defaults: defaults).today(ideas: ideas, now: now, calendar: calendar)
        XCTAssertEqual(state.batchIDs, [1, 2])
        XCTAssertEqual(state.backlogCount, 4)
        XCTAssertEqual(state.olderCount, 2)
        XCTAssertEqual(state.nextAvailable, 2)
        XCTAssertEqual(IdeaDailyBatch.state(ideas: ideas, batchIDs: [1, 2], now: now, size: 13, calendar: calendar)
            .nextAvailable, 4)
    }

    // MARK: - Copy

    func testRowCopy() {
        let ideas = fresh(4, from: 1).enumerated().map { index, item in
            idea(item.id, daysAgo: 0, createdAt: item.createdAt, title: index == 0 ? "Weekly demo" : nil)
        } + [idea(10, daysAgo: 40)]

        let open = IdeaDailyBatch.state(ideas: ideas, batchIDs: [1, 2], now: now, size: 13, calendar: calendar)
        XCTAssertEqual(open.rowPreview, "Today’s 2 ideas to judge. Top one: “Weekly demo”.")
        XCTAssertEqual(open.pillCount, 2)
        XCTAssertTrue(open.isUnread)
        XCTAssertEqual(open.rowMeta, "3 in the backlog · 1 older than 30 days")

        let one = IdeaDailyBatch.state(ideas: ideas, batchIDs: [1], now: now, size: 13, calendar: calendar)
        XCTAssertEqual(one.rowPreview, "Today’s 1 idea to judge. Top one: “Weekly demo”.")

        let judgedAll = judged(ideas, ids: [1, 2], status: "rejected", updatedAt: stamp(daysAgo: 0))
        let done = IdeaDailyBatch.state(ideas: judgedAll, batchIDs: [1, 2], now: now, size: 13, calendar: calendar)
        XCTAssertEqual(done.rowPreview, "Today’s batch done · 3 in the backlog")
        XCTAssertNil(done.pillCount)
        XCTAssertFalse(done.isUnread)
        XCTAssertEqual(done.rowMeta, "1 older than 30 days")

        let empty = IdeaDailyBatch.state(ideas: [idea(10, daysAgo: 40)], batchIDs: [], now: now, size: 13,
                                         calendar: calendar)
        XCTAssertEqual(empty.rowPreview, "Nothing to judge from the last 30 days")
        XCTAssertNil(empty.pillCount)
        XCTAssertFalse(empty.isUnread)
        XCTAssertEqual(empty.rowMeta, "1 in the backlog · 1 older than 30 days")

        let none = IdeaDailyBatch.state(ideas: [], batchIDs: [], now: now, size: 13, calendar: calendar)
        XCTAssertEqual(none.rowMeta, "")
        XCTAssertEqual(none.nextTitle, "Next 13")
    }

    func testPaneSubtitle() {
        let ideas = judged(fresh(6), ids: [1], status: "active", updatedAt: stamp(daysAgo: 0))
        let state = IdeaDailyBatch.state(ideas: ideas, batchIDs: [1, 2, 3], now: now, size: 3, calendar: calendar)
        XCTAssertEqual(state.paneSubtitle, "Today’s batch · 1 of 3 judged · 3 more in the backlog")
        XCTAssertEqual(state.nextTitle, "Next 3")
    }

    func testPressKeys() {
        XCTAssertEqual(IdeaBatchPress(key: "k"), .keep)
        XCTAssertEqual(IdeaBatchPress(key: "K"), .keep)
        XCTAssertEqual(IdeaBatchPress(key: "D"), .drop)
        XCTAssertEqual(IdeaBatchPress(key: "l"), .later)
        XCTAssertEqual(IdeaBatchPress(key: "t"), .makeTarget)
        XCTAssertNil(IdeaBatchPress(key: "x"))
        XCTAssertEqual(IdeaBatchPress.allCases.map(\.key), ["k", "d", "l", "t"])
        XCTAssertEqual(IdeaBatchPress.allCases.map(\.title), ["Keep", "Drop", "Later", "Make a Target…"])
    }
}
