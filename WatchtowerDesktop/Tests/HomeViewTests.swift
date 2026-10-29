import XCTest
import SwiftUI
import Observation
import ViewInspector
import GRDB
@testable import WatchtowerCore
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
        workbench: [HomeWorkbenchBlock] = [],
        coach: HomeCoachProposal? = nil,
        workbenchFailed: Bool = false,
        links: [HomeLinkRow] = [],
        linksFailed: Bool = false,
        numbers: HomeNumbers? = nil
    ) -> HomeSnapshot {
        HomeSnapshot(
            gettingReady: zone, firstSync: firstSync,
            feed: HomeFeedBuilder.feed(HomeFeedData(), now: Date(), calendar: .current, hidden: []),
            workbench: workbench, coach: coach, workbenchFailed: workbenchFailed,
            links: links, linksFailed: linksFailed, numbers: numbers)
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

    // MARK: - Layout

    /// The columns share the whole width about 60/40 (the mockup's 1.55 : 1).
    func testColumnsSplitTheWidth() {
        let layout = HomeColumnsLayout(spacing: 20)
        XCTAssertEqual(layout.columnWidths(1_040), [620, 400])
        XCTAssertEqual(layout.columnWidths(HomeContent.twoColumnWidth), [535, 345])
    }

    /// The layout takes the width it is offered; nil or an infinite one is
    /// the breakpoint (two columns), and two columns start at 900 pt.
    func testColumnsBreakpoint() {
        XCTAssertEqual(HomeColumnsLayout.layoutWidth(780), 780)
        XCTAssertEqual(HomeColumnsLayout.layoutWidth(1_040), 1_040)
        XCTAssertEqual(HomeColumnsLayout.layoutWidth(nil), 900)
        XCTAssertEqual(HomeColumnsLayout.layoutWidth(.infinity), 900)
        XCTAssertFalse(HomeColumnsLayout.isTwoColumn(899))
        XCTAssertTrue(HomeColumnsLayout.isTwoColumn(900))
        XCTAssertTrue(HomeColumnsLayout.isTwoColumn(1_040))
    }

    /// From the breakpoint up: side by side, each as tall as its content.
    func testColumnsFramesSideBySide() {
        let layout = HomeColumnsLayout(spacing: 20)
        var offered: [CGFloat] = []
        let frames = layout.frames(width: 1_040, count: 2) { index, width in
            offered.append(width)
            return index == 0 ? 600 : 250
        }
        XCTAssertEqual(offered, [620, 400])
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 620, height: 600), CGRect(x: 640, y: 0, width: 400, height: 250)])
    }

    /// The size the layout reports: two columns as tall as the taller one
    /// from the breakpoint up (nil is the breakpoint), else the stacked
    /// height of both plus the spacing.
    func testColumnsSize() {
        let layout = HomeColumnsLayout(spacing: 20)
        let heights: (Int, CGFloat) -> CGFloat = { index, _ in index == 0 ? 600 : 250 }
        XCTAssertEqual(layout.size(proposedWidth: 780, count: 2, height: heights), CGSize(width: 780, height: 870))
        XCTAssertEqual(layout.size(proposedWidth: 1_040, count: 2, height: heights), CGSize(width: 1_040, height: 600))
        XCTAssertEqual(layout.size(proposedWidth: nil, count: 2, height: heights), CGSize(width: 900, height: 600))
        XCTAssertEqual(layout.size(proposedWidth: 780, count: 0, height: heights), CGSize(width: 780, height: 0))
    }

    /// Below it: one column, feed first, the side column `spacing` under it,
    /// both offered the whole width.
    func testColumnsFramesStackBelowTheBreakpoint() {
        let layout = HomeColumnsLayout(spacing: 20)
        var offered: [CGFloat] = []
        let frames = layout.frames(width: 780, count: 2) { index, width in
            offered.append(width)
            return index == 0 ? 600 : 250
        }
        XCTAssertEqual(offered, [780, 780])
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 780, height: 600), CGRect(x: 0, y: 620, width: 780, height: 250)])
    }

    // MARK: - Getting ready

    func testGettingReadyShownRendersRowsInOrder() throws {
        let cards = [
            Self.card(.briefing, "Briefing", .waitingForSync(detail: nil)),
            Self.card(.digests, "Digests", .preparing(detail: nil)),
            Self.card(.tracks, "Tracks", .scheduled(.afterCurrentSync))
        ]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: [])))
        let all = try texts(view)
        XCTAssertEqual(all.filter(["Briefing", "Digests", "Tracks"].contains), ["Briefing", "Digests", "Tracks"])
        XCTAssertTrue(all.contains("Getting ready"))
        XCTAssertTrue(all.contains("· 0 of 3 ready"))
    }

    func testProgressDetail() {
        XCTAssertEqual(GettingReadyZoneView.progressDetail(ready: 6, of: 11), "6 of 11 ready")
        XCTAssertNil(GettingReadyZoneView.progressDetail(ready: 0, of: 0))
    }

    func testReadyFeaturesAreLinksOnTheReadyLine() throws {
        var tapped: HomeLink?
        let cards = [Self.card(.digests, "Digests", .ready), Self.card(.tracks, "Tracks", .preparing(detail: nil))]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: []))) { tapped = $0 }
        XCTAssertNoThrow(try view.inspect().find(text: "Ready"))
        XCTAssertNoThrow(try view.inspect().find(text: "· 1 of 2 ready"))
        XCTAssertThrowsError(try view.inspect().find(text: "Ready — Open"))
        let open = try view.inspect().find(button: "Digests")
        try open.tap()
        XCTAssertEqual(tapped, .feature(.digests))
        XCTAssertEqual(try open.accessibilityLabel().string(), "Open Digests")
    }

    func testPreparingCardShowsReadinessLine() throws {
        let preparing = Readiness.preparing(detail: "Messages · 3/10 channels")
        let cards = [Self.card(.digests, "Digests", preparing), Self.card(.memory, "Memory", nil)]
        let view = makeContent(viewSnapshot(.shown(cards: cards, sourceRows: [])))
        XCTAssertNoThrow(try view.inspect().find(text: FeatureReadiness.line(preparing)))
        // A nil readiness shows no line and is not a ready link.
        XCTAssertThrowsError(try view.inspect().find(button: "Memory"))
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
        XCTAssertNoThrow(try view.inspect().find(text: "Connect Jira to get Workload, Blockers, Project Map and Releases"))
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
        try view.inspect().find(button: "Hide").tap()
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

    // MARK: - Workbench zone

    private static func session(
        _ id: Int64, title: String, _ kind: SessionSwitcherPresentation.State.Kind
    ) -> SessionAgentStatus {
        SessionAgentStatus(
            sessionID: id, workbenchID: 1, workbenchName: "acme", title: title,
            state: SessionSwitcherPresentation.State(kind: kind, live: true), at: nil)
    }

    /// Open asks through the real query, so the rows are real `OwnerAsk`s.
    private func askRows(_ build: (Database) throws -> Void) throws -> WorkbenchAskRows {
        let db = try TestDatabase.create()
        return try db.write { d in
            try build(d)
            return try OwnerAskQueries.openAsksAllWorkbenches(d)
        }
    }

    private static func coach(_ lines: Int = 1, id: Int64 = 5) -> HomeCoachProposal {
        let after = (1...lines).map { "Line \($0)." }.joined(separator: "\n")
        return HomeCoachProposal(
            proposal: CoachProposalFixture.make(id: id, title: "Specs have no Non-goals", after: after), targetWorkbench: 2)
    }

    private static let coach = coach()

    func testNoBlocksHidesTheZone() throws {
        let all = try texts(makeContent(viewSnapshot()))
        XCTAssertFalse(all.contains("Workbench"))
        XCTAssertFalse(all.contains("Couldn't read Workbench — see the log."))
        // The coach row alone still shows the zone.
        XCTAssertTrue(try texts(makeContent(viewSnapshot(coach: Self.coach))).contains("Workbench"))
    }

    func testWorkbenchBlocksShowSessionsAndAsks() throws {
        let asks = try askRows { d in
            let acme = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            XCTAssertEqual(acme, 1, "the sessions' workbench")
            let api = try TestDatabase.insertWorkbench(d, name: "acme-api", folder: "/tmp/acme-api")
            try TestDatabase.insertOwnerAsk(d, projectID: api, kind: "question", title: "Which date format?")
        }
        let sessions = [
            Self.session(1, title: "Fix login redirect", .working),
            Self.session(2, title: "Export to CSV", .needsApproval)
        ]
        let blocks = HomeWorkbenchBuilder.blocks(sessions: sessions, asks: asks)
        var tapped: [HomeLink] = []
        let view = makeContent(viewSnapshot(workbench: blocks)) { tapped.append($0) }
        let all = try texts(view)
        let order = ["Workbench", "acme", "2 sessions", "Export to CSV", "Needs approval", "Fix login redirect",
                     "Working", "acme-api", "Question", "Which date format?"]
        XCTAssertEqual(Array(all.filter(order.contains).prefix(order.count)), order)

        try view.inspect().find(button: "Export to CSV").tap()
        try view.inspect().find(button: "Which date format?").tap()
        XCTAssertEqual(tapped.first, .workbench(WorkbenchRoute(projectID: 1, pane: .terminal, subjectID: 2)))
        XCTAssertEqual(tapped.last, HomeWorkbenchBuilder.link(for: try XCTUnwrap(asks.rows.first)))
        try view.inspect().find(button: "Open →").tap()
        XCTAssertEqual(tapped.last, .workbenches)
    }

    func testCoachRowIsTheLastRow() async throws {
        let blocks = HomeWorkbenchBuilder.blocks(
            sessions: [Self.session(1, title: "Rate limiter", .readyToCheck)],
            asks: WorkbenchAskRows(rows: [], unreadableIDs: []))
        let decided = expectation(description: "decided")
        var calls: [(Int64, Bool)] = []
        var opened: [Int64] = []
        let view = HomeContent(
            snapshot: viewSnapshot(workbench: blocks, coach: Self.coach), today: Date(), onLink: { _ in },
            onDecideCoach: { id, accept in
                calls.append((id, accept))
                decided.fulfill()
                return nil
            },
            onOpenCoach: { opened.append($0) },
            onHideGettingReady: {})
        let all = try texts(view)
        let rate = try XCTUnwrap(all.firstIndex(of: "Rate limiter"))
        let header = try XCTUnwrap(all.firstIndex(of: "Coach suggests · Session instructions · all workbenches"))
        XCTAssertLessThan(rate, header)
        XCTAssertEqual(Array(all[(header + 1)...].prefix(6)),
                       ["Specs have no Non-goals", "+ Line 1.", "Open in Analytics", "Decline", "Accept", "Stuck? Press "])
        try view.inspect().find(button: "Open in Analytics").tap()
        XCTAssertEqual(opened, [2])
        try view.inspect().find(button: "Accept").tap()
        await fulfillment(of: [decided], timeout: 2)
        XCTAssertEqual(calls.map(\.0), [5])
        XCTAssertEqual(calls.map(\.1), [true])
    }

    /// Decline asks first: one press runs nothing.
    func testHomeDeclineNeedsConfirmation() async throws {
        var calls: [(Int64, Bool)] = []
        let view = HomeContent(
            snapshot: viewSnapshot(coach: Self.coach), today: Date(), onLink: { _ in },
            onDecideCoach: { id, accept in calls.append((id, accept)); return nil },
            onHideGettingReady: {})
        try view.inspect().find(button: "Decline").tap()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(calls.isEmpty)
    }

    /// The "changed" note shows with no row left, and beside a replacement row.
    func testCoachNoteShowsWithAndWithoutARow() throws {
        let note = "That proposal changed — showing the next one"
        let bare = HomeContent(snapshot: viewSnapshot(), today: Date(), onLink: { _ in }, onHideGettingReady: {}, coachNote: note)
        let all = try texts(bare)
        XCTAssertTrue(all.contains("Workbench"), "the zone shows for the note alone")
        XCTAssertTrue(all.contains(note))
        let replaced = HomeContent(
            snapshot: viewSnapshot(coach: Self.coach(1, id: 6)), today: Date(), onLink: { _ in },
            onHideGettingReady: {}, coachNote: note)
        let both = try texts(replaced)
        XCTAssertTrue(both.contains(note))
        XCTAssertTrue(both.contains("Specs have no Non-goals"))
        XCTAssertFalse(try texts(makeContent(viewSnapshot(coach: Self.coach()))).contains(note))
    }

    /// A change over 4 lines shows its first 4 and "…", without Accept.
    func testLongChangeHasNoAccept() throws {
        let view = makeContent(viewSnapshot(coach: Self.coach(6)))
        let all = try texts(view)
        XCTAssertTrue(all.contains("+ Line 4."))
        XCTAssertFalse(all.contains("+ Line 5."))
        XCTAssertTrue(all.contains("…"))
        XCTAssertNoThrow(try view.inspect().find(button: "Open in Analytics"))
        XCTAssertNoThrow(try view.inspect().find(button: "Decline"))
        XCTAssertThrowsError(try view.inspect().find(button: "Accept"))
    }

    func testWorkbenchReadFailedIsSaid() throws {
        let all = try texts(makeContent(viewSnapshot(workbenchFailed: true)))
        XCTAssertTrue(all.contains("Workbench"))
        XCTAssertTrue(all.contains("Couldn't read Workbench — see the log."))
    }

    // MARK: - Links zone

    private static let links = [
        HomeLinkRow(kind: .briefing, title: "Briefing", status: "ready 08:12", highlighted: false, link: .briefing(id: 7)),
        HomeLinkRow(kind: .catchUp, title: "Catch-Up", status: "new recap", highlighted: true, link: .catchUp),
        HomeLinkRow(kind: .dayPlan, title: "Day plan", status: "2 of 6 done", highlighted: false,
                    link: .feature(.dayPlan)),
        HomeLinkRow(kind: .digests, title: "Digests", status: nil, highlighted: false, link: .feature(.digests))
    ]

    func testNoLinksHidesZone() throws {
        XCTAssertFalse(try texts(makeContent(viewSnapshot())).contains("Links"))
    }

    func testLinksRowsInOrderAndOpen() throws {
        var tapped: [HomeLink] = []
        let view = makeContent(viewSnapshot(links: Self.links)) { tapped.append($0) }
        let all = try texts(view)
        let order = ["Links", "Briefing", "ready 08:12", "Catch-Up", "new recap", "Day plan", "2 of 6 done", "Digests"]
        XCTAssertEqual(Array(all.filter(order.contains).prefix(order.count)), order)
        try view.inspect().find(button: "Catch-Up").tap()
        try view.inspect().find(button: "Day plan").tap()
        XCTAssertEqual(tapped, [.catchUp, .feature(.dayPlan)])
    }

    func testLinksReadFailedIsSaid() throws {
        let all = try texts(makeContent(viewSnapshot(links: Self.links, linksFailed: true)))
        XCTAssertTrue(all.contains("Couldn't read the links — see the log."))
        XCTAssertTrue(all.contains("Briefing"))
    }

    // MARK: - Numbers zone

    func testNumbersShowValuesLeaveOutNilAndDashFailed() throws {
        var numbers = HomeNumbers()
        numbers.messagesToMe = 38
        numbers.messagesSent = 12
        numbers.meetings = 4
        numbers.meetingHours = 3.5
        numbers.aiSpendUSD = 1.84
        numbers.plan5h = 41
        numbers.planWeek = 63
        numbers.workbenchCreated = 5
        numbers.workbenchDone = 3
        numbers.meetingsRecorded = 1
        let all = try texts(NumbersZoneView(numbers: numbers))
        for text in ["Today in numbers", "38 / 12", "messages to me / sent", "4 · 3.5 h", "meetings", "$1.84",
                     "AI spend", "41% · 63%", "Claude 5 h · week", "5 / 3", "workbench targets new / done", "1",
                     "meeting recorded"] {
            XCTAssertTrue(all.contains(text), text)
        }

        // Sources off: left out; a failed read: "—".
        var sparse = HomeNumbers()
        sparse.meetings = 0
        sparse.meetingHours = 0
        sparse.failed = ["aiSpendUSD"]
        let few = try texts(NumbersZoneView(numbers: sparse))
        XCTAssertTrue(few.contains("0"))
        XCTAssertTrue(few.contains("—"))
        XCTAssertTrue(few.contains("AI spend"))
        XCTAssertFalse(few.contains("messages to me / sent"))
        XCTAssertFalse(few.contains { $0.hasPrefix("Claude") })
        // Nothing at all: the header still shows.
        XCTAssertTrue(try texts(NumbersZoneView(numbers: HomeNumbers())).contains("Today in numbers"))
    }

    /// The feed owns the all-clear: the right column never says it.
    func testOneAllClearInTheFeed() throws {
        let view = makeContent(viewSnapshot(.hidden, numbers: HomeNumbers()))
        XCTAssertThrowsError(try view.inspect().find(text: "Nothing needs you right now."))
        XCTAssertNoThrow(try view.inspect().find(text: "Nothing is waiting for you."))
    }

    /// No counters on the rows; the header's "N of M ready" is the one
    /// (owner, ask #432).
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
        for text in try texts(view) where text != "· 1 of 5 ready" {
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
            waiting: waiting, hiddenWaiting: hidden, nowLabel: "10:40", ongoing: nil,
            laterToday: later,
            nextDay: nextDay, failed: failed)
    }

    private func feedZone(
        _ feed: HomeFeed,
        errors: [FeedRef: String] = [:],
        onLink: @escaping (HomeLink) -> Void = { _ in },
        onAct: @escaping (FeedAction, FeedRef) async -> Void = { _, _ in },
        onPage: @escaping (Bool) -> Void = { _ in },
        calendar: Calendar = .current
    ) -> FeedZoneView {
        FeedZoneView(
            feed: feed, errors: errors, onLink: onLink, onAct: onAct, onPage: onPage, now: Self.feedNow,
            calendar: calendar)
    }

    /// Row stamps and event times use the builder's calendar zone, not the
    /// process's: 08:00 UTC is 17:00 in UTC+9.
    func testFeedTimesUseTheCalendarZone() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let feed = Self.feed(
            waiting: [Self.row(.inbox(1), who: "Ann", text: "hi")],
            later: [Self.event("e1", "Payments review", minutes: 20)])
        let east = try texts(feedZone(feed, calendar: tokyo))
        XCTAssertTrue(east.contains("16:50"), "\(east)")
        XCTAssertTrue(east.contains("17:20"), "\(east)")
        let west = try texts(feedZone(feed, calendar: utc))
        XCTAssertTrue(west.contains("07:50"), "\(west)")
        XCTAssertTrue(west.contains("08:20"), "\(west)")
    }

    func testFeedShowsWaitingThenNowThenLater() throws {
        let feed = Self.feed(
            waiting: [Self.row(.inbox(1), who: "Ann", text: "is the review done?")],
            later: [Self.event("e1", "Payments review", minutes: 20)],
            nextDay: FeedDay(title: "Tomorrow", events: [Self.event("e2", "Daily standup", minutes: 1400)]))
        let all = try texts(feedZone(feed))
        // The zone's title, then its count.
        let order = ["Waiting on you", "· 1", "is the review done?", "10:40", "Payments review", "Tomorrow", "Daily standup"]
        XCTAssertEqual(all.filter(order.contains), order)
        XCTAssertTrue(all.contains("Catch-Up →"))
        XCTAssertFalse(all.contains("Nothing is waiting for you."))
        XCTAssertFalse(all.contains("Nothing else today."))

        // The same feed sits in Home's page; the Today header is gone.
        let snapshot = HomeSnapshot(gettingReady: .hidden, firstSync: nil, feed: feed)
        let page = try texts(makeContent(snapshot))
        XCTAssertTrue(page.contains("is the review done?"))
        XCTAssertFalse(page.contains("Today"))
    }

    /// Two columns (feed, then the 340 pt side column) when they fit, else one
    /// column with the feed first; the side column stacks Workbench, links,
    /// numbers.
    func testLayoutTwoColumnsThenOneColumn() throws {
        let snapshot = viewSnapshot(coach: Self.coach, links: Self.links, numbers: HomeNumbers())
        let page = try makeContent(snapshot).inspect()
        // One layout switches by width (`testColumnsFrames…`), so the feed
        // and the side column are each built once.
        XCTAssertThrowsError(try page.find(ViewType.ViewThatFits.self))
        XCTAssertEqual(page.findAll(FeedZoneView.self).count, 1)
        XCTAssertEqual(page.findAll(HomeSideColumn.self).count, 1)
        let side = try page.find(HomeSideColumn.self)
        XCTAssertNoThrow(try side.find(WorkbenchZoneView.self))
        XCTAssertNoThrow(try side.find(LinksZoneView.self))
        XCTAssertNoThrow(try side.find(NumbersZoneView.self))
        let all = try texts(makeContent(snapshot))
        let order = ["Workbench", "Links", "Today in numbers"]
        XCTAssertEqual(Array(all.filter(order.contains).prefix(3)), order)
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
        var paged: [Bool] = []
        let rows = (1...7).map { Self.row(.inbox($0), who: "Ann", text: "row \($0)") }
        try feedZone(Self.feed(waiting: rows, hidden: 2)) { _ in } onPage: { paged.append($0) }
            .inspect().find(button: "2 more").tap()
        XCTAssertEqual(paged, [true])
        let folded = try texts(feedZone(Self.feed(waiting: rows, hidden: 2)))
        let title = try XCTUnwrap(folded.firstIndex(of: "Waiting on you"))
        XCTAssertEqual(folded[title + 1], "· 9", "the header counts the folded rows too")

        // Expanded with nothing left: Show less only, and it collapses.
        let all = (1...9).map { Self.row(.inbox($0), who: "Ann", text: "row \($0)") }
        let open = feedZone(Self.feed(waiting: all)) { _ in } onPage: { paged.append($0) }
        XCTAssertThrowsError(try open.inspect().find(button: "Show 0 more"))
        try open.inspect().find(button: "Show less").tap()
        XCTAssertEqual(paged, [true, false])
        // Seven or fewer rows: neither line.
        XCTAssertThrowsError(try feedZone(Self.feed(waiting: rows)).inspect().find(button: "Show less"))
    }

    /// Collapsed over a long backlog, "N more" says what the first page
    /// adds (up to 50 rows in all), never every row left.
    func testNMoreNeverOverpromises() throws {
        let rows = (1...7).map { Self.row(.inbox($0), who: "Ann", text: "row \($0)") }
        let view = feedZone(Self.feed(waiting: rows, hidden: 193))
        XCTAssertNoThrow(try view.inspect().find(button: "43 more"))
        XCTAssertThrowsError(try view.inspect().find(button: "193 more"))
        XCTAssertThrowsError(try view.inspect().find(button: "Show less"))
        let all = try texts(view)
        let title = try XCTUnwrap(all.firstIndex(of: "Waiting on you"))
        XCTAssertEqual(all[title + 1], "· 200", "the header counts every row read")
    }

    /// Expanded with rows left: "Show 50 more" (fewer on the last page)
    /// beside Show less.
    func testShowMorePagesBesideShowLess() throws {
        var paged: [Bool] = []
        let rows = (1...HomeFeedBuilder.expandedLimit).map { Self.row(.inbox($0), who: "Ann", text: "row \($0)") }
        let view = feedZone(Self.feed(waiting: rows, hidden: 150)) { _ in } onPage: { paged.append($0) }
        try view.inspect().find(button: "Show 50 more").tap()
        try view.inspect().find(button: "Show less").tap()
        XCTAssertEqual(paged, [true, false])
        let lastPage = feedZone(Self.feed(waiting: rows, hidden: 12))
        XCTAssertNoThrow(try lastPage.inspect().find(button: "Show 12 more"))
        XCTAssertNoThrow(try lastPage.inspect().find(button: "Show less"))
        XCTAssertThrowsError(try lastPage.inspect().find(button: "12 more"))
    }

    /// Row stamps reuse one formatter per pattern and calendar; another zone
    /// gets its own.
    func testFeedTimeReusesFormatters() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let first = FeedTime.formatter("HH:mm", tokyo)
        let again = FeedTime.formatter("HH:mm", tokyo)
        XCTAssertTrue(first === again)
        XCTAssertFalse(first === FeedTime.formatter("HH:mm", utc))
        XCTAssertFalse(first === FeedTime.formatter("EEE", tokyo))
        XCTAssertEqual(FeedTime.string(Self.feedNow, "HH:mm", utc), "08:00")
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

    /// The hover buttons are hidden from accessibility while invisible; the
    /// row offers Open, and Done / Hide only when it has them, as named
    /// accessibility actions.
    func testRowActionsReachAccessibility() async throws {
        let acted = expectation(description: "acted")
        acted.expectedFulfillmentCount = 2
        var calls: [String] = []
        var opened: [HomeLink] = []
        let slack = feedZone(Self.feed(waiting: [Self.row(.inbox(9), who: "Ann", text: "hi")])) {
            opened.append($0)
        } onAct: { action, ref in
            calls.append("\(action) \(ref)")
            acted.fulfill()
        }
        for title in ["Open", "Done", "Hide"] {
            XCTAssertTrue(try slack.inspect().find(button: title).accessibilityHidden(), title)
        }
        let actions = try slack.inspect().find(FeedRowView.self).hStack().accessibilityActions()
        try actions.find(button: "Done").tap()
        try actions.find(button: "Hide").tap()
        try actions.find(button: "Open").tap()
        await fulfillment(of: [acted], timeout: 2)
        XCTAssertEqual(Set(calls), ["done inbox(9)", "hide inbox(9)"])
        XCTAssertEqual(opened, [.permalink(URL(string: "https://example.com/1")!)])

        let proposal = Self.row(.proposal(4), kind: .proposal, chip: "Proposal", who: "Send the note", text: "review in Inbox",
                                actions: [])
        let none = try feedZone(Self.feed(waiting: [proposal])).inspect().find(FeedRowView.self).hStack().accessibilityActions()
        XCTAssertNoThrow(try none.find(button: "Open"))
        XCTAssertThrowsError(try none.find(button: "Done"))
        XCTAssertThrowsError(try none.find(button: "Hide"))
    }

    func testEmptyFeedLine() throws {
        let all = try texts(feedZone(Self.feed()))
        XCTAssertTrue(all.contains("Nothing is waiting for you."))
        XCTAssertTrue(all.contains("Nothing else today."))
        // No count at zero: the header's title is followed by its trailing link.
        let title = try XCTUnwrap(all.firstIndex(of: "Waiting on you"))
        XCTAssertEqual(all[title + 1], "Catch-Up →")
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
        let automations = try texts(feedZone(Self.feed(failed: [.automations])))
        XCTAssertTrue(automations.contains("Couldn't read automation notes — see the log."))
        XCTAssertFalse(automations.contains("Nothing is waiting for you."))
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
