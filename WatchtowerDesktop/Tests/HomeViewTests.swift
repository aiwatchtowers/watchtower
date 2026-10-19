import XCTest
import SwiftUI
import Observation
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
final class HomeViewTests: XCTestCase {
    private static func card(_ feature: ReadinessFeature, _ title: String, _ readiness: Readiness?) -> GettingReadyCard {
        GettingReadyCard(
            feature: feature, copy: FeatureCardCopy(title: title, whatItIs: "\(title) sentence."), readiness: readiness)
    }

    private static let firstSync = FirstSyncLine(
        title: "Syncing Slack for the last 30 days — usually 3–5 min",
        detail: "Fetching channels · started 1 min ago")

    private func makeContent(
        _ snapshot: HomeSnapshot?,
        today: Date = Date(),
        onLink: @escaping (HomeLink) -> Void = { _ in },
        onHide: @escaping () -> Void = {}
    ) -> HomeContent {
        HomeContent(snapshot: snapshot, today: today, onLink: onLink, onHideGettingReady: onHide)
    }

    private func viewSnapshot(
        _ zone: GettingReadyZone = .hidden,
        firstSync: FirstSyncLine? = nil,
        today: [TodayCard] = [],
        readFailed: Bool = false,
        failed: Set<TodayCardKind> = []
    ) -> HomeSnapshot {
        HomeSnapshot(
            gettingReady: zone, firstSync: firstSync, today: today, todayReadFailed: readFailed, todayFailed: failed,
            feed: HomeFeedBuilder.feed(HomeFeedData(), now: Date(), calendar: .current, expanded: false, hidden: []))
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: - Header

    func testHeaderShowsHomeAndDate() throws {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        let view = makeContent(viewSnapshot())
        XCTAssertNoThrow(try view.inspect().find(text: "Home"))
        XCTAssertNoThrow(try makeContent(viewSnapshot(), today: now).inspect().find(text: formatter.string(from: now)))
        // Before the first snapshot: the header and a spinner, no all-clear.
        let loading = makeContent(nil)
        XCTAssertNoThrow(try loading.inspect().find(text: "Home"))
        XCTAssertNoThrow(try loading.inspect().find(ViewType.ProgressView.self))
        XCTAssertThrowsError(try loading.inspect().find(text: "Nothing needs you right now."))
    }

    // MARK: - Getting ready

    func testGettingReadyShownRendersCardsInOrder() throws {
        let cards = [
            Self.card(.briefing, "Briefing", .waitingForSync(detail: nil)),
            Self.card(.digests, "Digests", .preparing(detail: nil)),
            Self.card(.tracks, "Tracks", .scheduled(.afterCurrentSync))
        ]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: [])))
        let all = try texts(view)
        XCTAssertEqual(all.filter(["Briefing", "Digests", "Tracks"].contains), ["Briefing", "Digests", "Tracks"])
        XCTAssertTrue(all.contains("Getting ready"))
        XCTAssertTrue(all.contains("Watchtower is preparing these from your sources"))
        XCTAssertTrue(all.contains("Digests sentence."))
    }

    func testReadyCardShowsOpenAndCallsLink() throws {
        var tapped: HomeLink?
        let cards = [Self.card(.digests, "Digests", .ready), Self.card(.tracks, "Tracks", .preparing(detail: nil))]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: []))) { tapped = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "Ready"))
        XCTAssertThrowsError(try view.inspect().find(text: "Ready — Open"))
        let open = try view.inspect().find(button: "Open")
        XCTAssertEqual(try open.accessibilityLabel().string(), "Open Digests")
        try open.tap()
        XCTAssertEqual(tapped, .feature(.digests))
    }

    func testPreparingCardShowsReadinessLine() throws {
        let preparing = Readiness.preparing(detail: "Messages · 3/10 channels")
        let cards = [Self.card(.digests, "Digests", preparing), Self.card(.memory, "Memory", nil)]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: [])))
        XCTAssertNoThrow(try view.inspect().find(text: FeatureReadiness.line(preparing)))
        // A nil readiness shows no line and no Open.
        XCTAssertThrowsError(try view.inspect().find(button: "Open"))
        XCTAssertNoThrow(try view.inspect().find(text: "Memory"))
    }

    /// No owner (OWNER-02): the owner-gated card says what to connect, or
    /// which source it waits on, and opens Connections.
    func testOwnerGapCardShowsLineAndOpensConnections() throws {
        for gap in [ReadinessSource.ownerIdentity, .ownerIdentityPending("Jira")] {
            var tapped: HomeLink?
            let cards = [Self.card(.briefing, "Briefing", .needsSource(gap))]
            let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: []))) { tapped = $0 }
            XCTAssertNoThrow(try view.inspect().find(text: FeatureReadiness.line(.needsSource(gap))))
            try view.inspect().find(button: "Open Connections").tap()
            XCTAssertEqual(tapped, .connect(gap))
        }
        XCTAssertEqual(FeatureReadiness.line(.needsSource(.ownerIdentityPending("Jira"))), "Waiting for your Jira identity…")
        // Any other card has no such button.
        let other = makeContent(viewSnapshot(.shown(cards: [Self.card(.digests, "Digests", .preparing(detail: nil))], sourceRows: [])))
        XCTAssertThrowsError(try other.inspect().find(button: "Open Connections"))
    }

    /// #575: a card waiting on Slack Digests offers Turn on Slack Digests
    /// (one call to action, no "— Turn on" in the line), with the tabs'
    /// progress, busy and error.
    func testNeedsDigestsCardTurnsOnSlackDigests() throws {
        var tapped: HomeLink?
        let cards = [Self.card(.tracks, "Tracks", .needsDigests)]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: []))) { tapped = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "Needs Slack Digests"))
        try view.inspect().find(button: "Turn on Slack Digests").tap()
        XCTAssertEqual(tapped, .turnOn(featureID: "slack-digests"))

        let busy = HomeContent(
            snapshot: viewSnapshot(.shown(cards: cards, sourceRows: [])), today: Date(),
            digestsTurnOn: DigestsTurnOnState(busy: true, isTurningOn: true), onLink: { _ in }, onHideGettingReady: {})
        XCTAssertTrue(try busy.inspect().find(button: "Turn on Slack Digests").isDisabled())
        XCTAssertNoThrow(try busy.inspect().find(ViewType.ProgressView.self))

        // The restart failed: tracks is scheduled again, the retry stays.
        let failedCards = [Self.card(.tracks, "Tracks", .scheduled(.nextCycle(minutes: 15)))]
        let failed = HomeContent(
            snapshot: viewSnapshot(.shown(cards: failedCards, sourceRows: [])), today: Date(),
            digestsTurnOn: DigestsTurnOnState(error: "boom"), onLink: { tapped = $0 }, onHideGettingReady: {})
        XCTAssertNoThrow(try failed.inspect().find(text: "boom"))
        tapped = nil
        try failed.inspect().find(button: "Try again").tap()
        XCTAssertEqual(tapped, .turnOn(featureID: "slack-digests"))

        // R3: two cards with the same error show it, and its retry, once.
        let both = [
            Self.card(.tracks, "Tracks", .scheduled(.nextCycle(minutes: 15))),
            Self.card(.peopleCards, "People cards", .needsDigests)
        ]
        let once = HomeContent(
            snapshot: viewSnapshot(.shown(cards: both, sourceRows: [])), today: Date(),
            digestsTurnOn: DigestsTurnOnState(error: "boom"), onLink: { _ in }, onHideGettingReady: {})
        XCTAssertEqual(try once.inspect().findAll(ViewType.Text.self) { try $0.string() == "boom" }.count, 1)
        XCTAssertEqual(try once.inspect().findAll(ViewType.Button.self) {
            try $0.labelView().text().string() == "Try again"
        }.count, 1)
        XCTAssertThrowsError(try once.inspect().find(button: "Turn on Slack Digests"))
        XCTAssertEqual(GettingReadyZoneView.digestsOfferingCards(both, DigestsTurnOnState()), [.tracks, .peopleCards])
        XCTAssertEqual(GettingReadyZoneView.digestsOfferingCards(both, DigestsTurnOnState(error: "boom")), [.tracks])

        // Other cards never offer it.
        let other = makeContent(viewSnapshot(.shown(cards: [Self.card(.ideas, "Ideas", .scheduled(.inHours(6)))], sourceRows: [])))
        XCTAssertThrowsError(try other.inspect().find(button: "Turn on Slack Digests"))
    }

    func testFirstSyncLineOnTop() throws {
        let cards = [Self.card(.digests, "Digests", .waitingForSync(detail: nil))]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: []), firstSync: Self.firstSync))
        let all = try texts(view)
        let title = try XCTUnwrap(all.firstIndex(of: Self.firstSync.title))
        let detail = try XCTUnwrap(all.firstIndex(of: Self.firstSync.detail))
        let digests = try XCTUnwrap(all.firstIndex(of: "Digests"))
        XCTAssertLessThan(title, detail)
        XCTAssertLessThan(detail, digests)
        // No zone, no line.
        XCTAssertThrowsError(try makeContent(viewSnapshot(.hidden, firstSync: Self.firstSync))
            .inspect().find(text: Self.firstSync.title))
    }

    func testJiraSourceRowText() throws {
        var tapped: HomeLink?
        let rows = [GettingReadySourceRow(source: .jira, features: [.jira])]
        let view = makeContent(viewSnapshot(.shown(cards: [], sourceRows: rows))) { tapped = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "Connect Jira to get Boards, Workload, Blockers, Project Map and Releases"))
        try view.inspect().find(button: "Connect Jira").tap()
        XCTAssertEqual(tapped, .connect(.jira))
        // Two features on one tab name it once; the others by their tab.
        let slack = GettingReadySourceRow(source: .slack, features: [.digests, .streamDigests, .tracks])
        XCTAssertEqual(GettingReadyZoneView.connectLine(slack), "Connect Slack to get Digests and Tracks")
        let calendar = GettingReadySourceRow(source: .calendar, features: [.calendar])
        XCTAssertEqual(GettingReadyZoneView.connectLine(calendar), "Connect a calendar to get Calendar")
    }

    func testHideButtonCallsHide() throws {
        var hidden = 0
        let cards = [Self.card(.digests, "Digests", .preparing(detail: nil))]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: []))) { _ in } onHide: { hidden += 1 }
        let hide = try view.inspect().find(ViewType.Button.self) {
            try $0.accessibilityLabel().string() == "Hide Getting ready"
        }
        try hide.tap()
        XCTAssertEqual(hidden, 1)
    }

    func testAllReadyLine() throws {
        let view = makeContent(viewSnapshot(.allReady))
        XCTAssertNoThrow(try view.inspect().find(text: "Everything's ready"))
        XCTAssertThrowsError(try view.inspect().find(text: "Getting ready"))
        let hidden = makeContent(viewSnapshot(.hidden))
        XCTAssertThrowsError(try hidden.inspect().find(text: "Everything's ready"))
        XCTAssertThrowsError(try hidden.inspect().find(text: "Getting ready"))
    }

    // MARK: - Today

    private static let reviewRoute = WorkbenchRoute.forAsk(projectID: 1, sessionID: nil, askID: 12)

    private static let todayCards = [
        TodayCard(
            kind: .sinceYouWereAway, eyebrow: "SINCE YOU WERE AWAY · SINCE MON 18:30",
            body: "Two threads need you", link: .catchUp),
        TodayCard(kind: .briefing, eyebrow: "BRIEFING", body: "A lighter day.", link: .briefing(id: 7)),
        TodayCard(
            kind: .agentsWaiting, eyebrow: "AGENTS WAITING · 2",
            items: [
                TodayItem(chip: "Check", title: "Check the build", detail: "acme", tone: nil,
                          link: .workbench(.forAsk(projectID: 1, sessionID: nil, askID: 11))),
                TodayItem(chip: "Review", title: "Review feedback", detail: "acme", tone: nil,
                          link: .workbench(reviewRoute))
            ],
            link: .workbenches)
    ]

    func testTodayCardsInSnapshotOrder() throws {
        let view = makeContent(viewSnapshot(today: Self.todayCards))
        let eyebrows = Self.todayCards.map(\.eyebrow)
        // ViewThatFits holds both layouts (two columns, then one), each in order.
        XCTAssertEqual(try texts(view).filter(eyebrows.contains), eyebrows + eyebrows)
        XCTAssertThrowsError(try view.inspect().find(text: "Today"))
        XCTAssertNoThrow(try view.inspect().find(text: "Two threads need you"))
        XCTAssertNoThrow(try view.inspect().find(text: "A lighter day."))
        XCTAssertNoThrow(try view.inspect().find(text: "Check"))
        XCTAssertThrowsError(try view.inspect().find(text: "Nothing needs you right now."))
    }

    func testItemRowCallsItsLink() throws {
        var tapped: [HomeLink] = []
        let view = makeContent(viewSnapshot(today: Self.todayCards)) { tapped.append($0) }
        try view.inspect().find(button: "Review feedback").tap()
        XCTAssertEqual(tapped, [.workbench(Self.reviewRoute)])
        // The card's own header goes to the card's link.
        try view.inspect().find(button: "A lighter day.").tap()
        XCTAssertEqual(tapped.last, .briefing(id: 7))
    }

    func testNothingNeedsYouLine() throws {
        let view = makeContent(viewSnapshot(.hidden))
        XCTAssertNoThrow(try view.inspect().find(text: "Nothing needs you right now."))
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self) {
            try $0.actualImage().name() == "checkmark.circle"
        })
        XCTAssertThrowsError(try view.inspect().find(text: "Couldn't read today's items — see the log."))
    }

    func testReadFailedIsNotAllClear() throws {
        for failed in [viewSnapshot(readFailed: true, failed: [.agentsWaiting]), viewSnapshot(failed: [.briefing])] {
            XCTAssertTrue(failed.showsReadError)
            let view = makeContent(failed)
            XCTAssertNoThrow(try view.inspect().find(text: "Couldn't read today's items — see the log."))
            XCTAssertThrowsError(try view.inspect().find(text: "Nothing needs you right now."))
        }
    }

    func testNoCounterText() throws {
        let cards = [
            Self.card(.digests, "Digests", .ready),
            Self.card(.tracks, "Tracks", .preparing(detail: nil)),
            Self.card(.peopleCards, "People", .waitingForSync(detail: nil)),
            Self.card(.ideas, "Ideas", .scheduled(.inHours(5))),
            Self.card(.memory, "Memory", .error(message: "CLI timed out"))
        ]
        let rows = [GettingReadySourceRow(source: .jira, features: [.jira])]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: rows), firstSync: Self.firstSync))
        let counter = try NSRegularExpression(pattern: #"\d+ of \d+"#)
        for text in try texts(view) {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(counter.firstMatch(in: text, range: range), text)
        }
    }

    // MARK: - Feed

    private static let feedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(
        _ ref: FeedRef,
        kind: FeedKind = .slack,
        chip: String = "Mention",
        who: String,
        text: String,
        read: Bool = false,
        actions: Set<FeedAction> = [.done, .hide]
    ) -> FeedRow {
        FeedRow(
            id: ref, kind: kind, chip: chip, who: who, whereText: "#eng", text: text,
            stamp: feedNow.addingTimeInterval(-600), read: read, actions: actions,
            link: .permalink(URL(string: "https://example.com/1")!))
    }

    private static func event(_ id: String, _ title: String, minutes: Double, chip: String = "Meeting") -> FeedEvent {
        let start = feedNow.addingTimeInterval(minutes * 60)
        return FeedEvent(
            id: .event(id), start: start, end: start.addingTimeInterval(1800), title: title, chip: chip,
            prepReady: false, isNext: false, isOngoing: false, link: .calendarEvent(id: id))
    }

    private static func feed(
        waiting: [FeedRow] = [],
        hidden: Int = 0,
        later: [FeedEvent] = [],
        nextDay: FeedDay? = nil,
        failed: Set<FeedSource> = []
    ) -> HomeFeed {
        HomeFeed(
            waiting: waiting, hiddenWaiting: hidden, nowLabel: "10:40", ongoing: nil, laterToday: later,
            nextDay: nextDay, failed: failed)
    }

    private func feedZone(
        _ feed: HomeFeed,
        errors: [FeedRef: String] = [:],
        onLink: @escaping (HomeLink) -> Void = { _ in },
        onAct: @escaping (FeedAction, FeedRef) async -> Void = { _, _ in },
        onExpand: @escaping (Bool) -> Void = { _ in }
    ) -> FeedZoneView {
        FeedZoneView(
            feed: feed, errors: errors, onLink: onLink, onAct: onAct, onExpand: onExpand, now: Self.feedNow)
    }

    func testFeedShowsWaitingThenNowThenLater() throws {
        let feed = Self.feed(
            waiting: [Self.row(.inbox(1), who: "Ann", text: "is the review done?")],
            later: [Self.event("e1", "Payments review", minutes: 20)],
            nextDay: FeedDay(title: "Tomorrow", events: [Self.event("e2", "Daily standup", minutes: 1400)]))
        let all = try texts(feedZone(feed))
        let order = ["WAITING ON YOU · 1", "is the review done?", "10:40", "Payments review", "Tomorrow", "Daily standup"]
        XCTAssertEqual(all.filter(order.contains), order)
        XCTAssertTrue(all.contains("Catch-Up →"))
        XCTAssertFalse(all.contains("Nothing is waiting for you."))
        XCTAssertFalse(all.contains("Nothing else today."))

        // The same feed sits in Home's page; the Today header is gone.
        let snapshot = HomeSnapshot(
            gettingReady: .hidden, firstSync: nil, today: [], todayReadFailed: false, feed: feed)
        let page = try texts(makeContent(snapshot))
        XCTAssertTrue(page.contains("is the review done?"))
        XCTAssertFalse(page.contains("Today"))
    }

    /// Two columns (feed, then the 340 pt card stack) when they fit, else one
    /// column with the feed first.
    func testLayoutTwoColumnsThenOneColumn() throws {
        let layout = try makeContent(viewSnapshot(today: Self.todayCards)).inspect().find(ViewType.ViewThatFits.self)
        let wide = try layout.hStack(0)
        XCTAssertNoThrow(try wide.view(FeedZoneView.self, 0))
        XCTAssertNoThrow(try wide.view(TodayZoneView.self, 1))
        let narrow = try layout.vStack(1)
        XCTAssertNoThrow(try narrow.view(FeedZoneView.self, 0))
        XCTAssertNoThrow(try narrow.view(TodayZoneView.self, 1))
    }

    func testCatchUpLinkAndRowOpen() throws {
        var tapped: [HomeLink] = []
        let feed = Self.feed(waiting: [Self.row(.inbox(1), who: "Ann", text: "hi")])
        let view = feedZone(feed) { tapped.append($0) }
        try view.inspect().find(button: "Catch-Up →").tap()
        try view.inspect().find(button: "Open").tap()
        XCTAssertEqual(tapped, [.catchUp, .permalink(URL(string: "https://example.com/1")!)])
    }

    func testNMoreExpands() throws {
        var expanded: [Bool] = []
        let rows = (1...7).map { Self.row(.inbox($0), who: "Ann", text: "row \($0)") }
        try feedZone(Self.feed(waiting: rows, hidden: 2)) { _ in } onExpand: { expanded.append($0) }
            .inspect().find(button: "2 more").tap()
        XCTAssertEqual(expanded, [true])
        XCTAssertNoThrow(try feedZone(Self.feed(waiting: rows, hidden: 2)).inspect().find(text: "WAITING ON YOU · 9"))

        // Expanded: every row, and Show less collapses.
        let all = (1...9).map { Self.row(.inbox($0), who: "Ann", text: "row \($0)") }
        let open = feedZone(Self.feed(waiting: all)) { _ in } onExpand: { expanded.append($0) }
        XCTAssertThrowsError(try open.inspect().find(button: "0 more"))
        try open.inspect().find(button: "Show less").tap()
        XCTAssertEqual(expanded, [true, false])
        // Seven or fewer rows: neither line.
        XCTAssertThrowsError(try feedZone(Self.feed(waiting: rows)).inspect().find(button: "Show less"))
    }

    func testProposalRowHasNoDoneButton() async throws {
        let proposal = Self.row(.proposal(4), kind: .proposal, chip: "Proposal", who: "Send the note", text: "review in Inbox",
                                actions: [])
        let view = feedZone(Self.feed(waiting: [proposal]))
        XCTAssertNoThrow(try view.inspect().find(button: "Open"))
        XCTAssertThrowsError(try view.inspect().find(button: "Done"))
        XCTAssertThrowsError(try view.inspect().find(button: "Hide"))

        // A slack row offers both, and they call onAct with the row's ref.
        let acted = expectation(description: "acted")
        acted.expectedFulfillmentCount = 2
        var calls: [String] = []
        let slack = feedZone(Self.feed(waiting: [Self.row(.inbox(9), who: "Ann", text: "hi")])) { _ in } onAct: { action, ref in
            calls.append("\(action) \(ref)")
            acted.fulfill()
        }
        try slack.inspect().find(button: "Done").tap()
        try slack.inspect().find(button: "Hide").tap()
        await fulfillment(of: [acted], timeout: 2)
        XCTAssertEqual(Set(calls), ["done inbox(9)", "hide inbox(9)"])
    }

    func testEmptyFeedLine() throws {
        let all = try texts(feedZone(Self.feed()))
        XCTAssertTrue(all.contains("Nothing is waiting for you."))
        XCTAssertTrue(all.contains("Nothing else today."))
        XCTAssertTrue(all.contains("WAITING ON YOU"))
        XCTAssertFalse(all.contains { $0.hasPrefix("WAITING ON YOU ·") })
        // The NOW line still shows.
        XCTAssertTrue(all.contains("10:40"))
    }

    func testFailedInboxShowsErrorNotAllClear() throws {
        let all = try texts(feedZone(Self.feed(failed: [.inbox, .calendar])))
        XCTAssertTrue(all.contains("Couldn't read Slack and mail — see the log."))
        XCTAssertTrue(all.contains("Couldn't read the calendar — see the log."))
        XCTAssertFalse(all.contains("Nothing is waiting for you."))
        XCTAssertFalse(all.contains("Nothing else today."))
        let others = try texts(feedZone(Self.feed(failed: [.reminders, .proposals, .targets])))
        for name in ["reminders", "proposals", "targets"] {
            XCTAssertTrue(others.contains("Couldn't read \(name) — see the log."), name)
        }
        XCTAssertFalse(others.contains("Nothing is waiting for you."))
        // A row whose Done failed shows its error.
        let row = Self.row(.inbox(3), who: "Ann", text: "hi")
        XCTAssertNoThrow(try feedZone(Self.feed(waiting: [row]), errors: [.inbox(3): "exit 1"]).inspect().find(text: "exit 1"))
    }

    func testTomorrowTitleNeverToday() throws {
        let monday = FeedDay(title: "Monday", events: [Self.event("e3", "Planning", minutes: 4000)])
        let all = try texts(feedZone(Self.feed(nextDay: monday)))
        XCTAssertTrue(all.contains("Monday"))
        XCTAssertFalse(all.contains { $0.localizedCaseInsensitiveContains("today") && $0 != "Nothing else today." })
        let monIndex = try XCTUnwrap(all.firstIndex(of: "Monday"))
        let nowIndex = try XCTUnwrap(all.firstIndex(of: "10:40"))
        XCTAssertLessThan(nowIndex, monIndex)
    }

    // MARK: - Navigation

    /// Coming back to Home shows the snapshot AppState already holds: the
    /// view itself never starts a read.
    func testSwitchingBackShowsSnapshotWithoutRead() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.homeCenter.beginReading(pool: manager.dbPool)
        defer { appState.homeCenter.endReading() }

        let landed = expectation(description: "snapshot landed")
        func check() {
            if appState.homeCenter.snapshot != nil {
                landed.fulfill()
                return
            }
            withObservationTracking { _ = appState.homeCenter.snapshot } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [landed], timeout: 5)
        appState.selectedDestination = .targets
        let reads = appState.homeCenter.todayReads

        appState.selectedDestination = .home
        _ = try ViewRenderProbe(size: NSSize(width: 900, height: 700))
            .render(HomeView().environment(appState), NSAppearance(named: .aqua) ?? NSAppearance())
        XCTAssertEqual(appState.homeCenter.todayReads, reads)
        let content = makeContent(appState.homeCenter.snapshot)
        XCTAssertThrowsError(try content.inspect().find(ViewType.ProgressView.self))
    }
}
