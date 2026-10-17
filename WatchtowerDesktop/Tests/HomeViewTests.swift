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
            gettingReady: zone, firstSync: firstSync, today: today, todayReadFailed: readFailed, todayFailed: failed)
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

    private static let todayCards = [
        TodayCard(
            kind: .waitingOnYou, eyebrow: "WAITING ON YOU · 2",
            items: [TodayItem(chip: "Proposal", title: "Send the follow-up", detail: nil, tone: nil, link: .inbox)],
            link: .inbox),
        TodayCard(
            kind: .nextMeeting, eyebrow: "NEXT MEETING · IN 25 MIN", title: "Design review",
            body: "11:30–12:00", link: .calendarEvent(id: "evt-1")),
        TodayCard(kind: .briefing, eyebrow: "BRIEFING", body: "A lighter day.", link: .briefing(id: 7)),
        TodayCard(
            kind: .myTargets, eyebrow: "MY TARGETS",
            items: [
                TodayItem(chip: nil, title: "Draft the plan", detail: "In progress", tone: .inProgress, link: .target(id: 11)),
                TodayItem(chip: nil, title: "Review feedback", detail: "Due today", tone: .dueToday, link: .target(id: 12))
            ],
            link: .targets)
    ]

    func testTodayCardsInSnapshotOrder() throws {
        let view = makeContent(viewSnapshot(today: Self.todayCards))
        let eyebrows = Self.todayCards.map(\.eyebrow)
        XCTAssertEqual(try texts(view).filter(eyebrows.contains), eyebrows)
        XCTAssertNoThrow(try view.inspect().find(text: "Today"))
        XCTAssertNoThrow(try view.inspect().find(text: "Design review"))
        XCTAssertNoThrow(try view.inspect().find(text: "A lighter day."))
        XCTAssertNoThrow(try view.inspect().find(text: "Proposal"))
        XCTAssertThrowsError(try view.inspect().find(text: "Nothing needs you right now."))
    }

    func testItemRowCallsItsLink() throws {
        var tapped: [HomeLink] = []
        let view = makeContent(viewSnapshot(today: Self.todayCards)) { tapped.append($0) }
        try view.inspect().find(button: "Review feedback").tap()
        XCTAssertEqual(tapped, [.target(id: 12)])
        // The card's own header goes to the card's link.
        try view.inspect().find(button: "Design review").tap()
        XCTAssertEqual(tapped.last, .calendarEvent(id: "evt-1"))
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
        for failed in [viewSnapshot(readFailed: true, failed: [.myTargets]), viewSnapshot(failed: [.briefing])] {
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
