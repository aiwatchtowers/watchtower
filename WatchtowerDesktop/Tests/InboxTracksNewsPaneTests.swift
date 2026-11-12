import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Track my threads' reading pane (inbox redesign, phase 3): the threads
/// with news, the fold past the visible ones, the quiet note and its
/// Stop Tracking Quiet Ones… press; the back bar of an opened thread.
@MainActor
final class InboxTracksNewsPaneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(
        id: Int,
        text: String? = nil,
        hasUpdates: Bool = false,
        lastEventDaysAgo: Double = 1,
        newEvents: Int = 0,
        summary: String = "",
        attachment: Bool = false
    ) -> InboxTrackCard {
        let columns: [String: (any DatabaseValueConvertible)?] = [
            "id": id, "text": text ?? "Thread \(id)", "has_updates": hasUpdates,
            "read_at": "2026-01-01T00:00:00Z", "category": "task", "assignee_user_id": "acme:U1"
        ]
        return InboxTrackCard(
            track: Track(row: Row(columns)),
            lastEventAt: now.addingTimeInterval(-lastEventDaysAgo * 24 * 3600),
            newEventCount: newEvents,
            latestEventSummary: summary,
            newestRefHasAttachment: attachment
        )
    }

    private func news(_ ids: ClosedRange<Int>) -> [InboxTrackCard] {
        ids.map { card(id: $0, hasUpdates: true, lastEventDaysAgo: Double($0)) }
    }

    private func pane(
        _ tracks: [InboxTrackCard],
        onOpenThread: @escaping (Int) -> Void = { _ in },
        onAllThreads: @escaping () -> Void = {}
    ) -> InboxTracksNewsPane {
        InboxTracksNewsPane(
            summary: TrackThreadsSummary.build(tracks: tracks, now: now),
            quietPress: InboxBulkPressModel(),
            onOpenThread: onOpenThread,
            onAllThreads: onAllThreads
        )
    }

    private func rowIDs(_ sut: InboxTracksNewsPane) throws -> [String] {
        let rows = try sut.inspect().findAll(ViewType.Button.self) { button in
            (try? button.accessibilityIdentifier())?.hasPrefix("inbox.tracksNews.row.") ?? false
        }
        return try rows.map { try $0.accessibilityIdentifier() }
    }

    func testListsVisibleNewsAndFoldsTheRest() throws {
        let sut = pane(news(1...7))
        XCTAssertEqual(
            try rowIDs(sut),
            (1...5).map { "inbox.tracksNews.row.\($0)" }
        )
        XCTAssertNoThrow(try sut.inspect().find(text: "With news for you · 7"))
        XCTAssertNoThrow(try sut.inspect().find(button: "2 more with news"))

        let five = pane(news(1...5))
        XCTAssertEqual(try rowIDs(five).count, 5)
        XCTAssertThrowsError(try five.inspect().find(ViewType.Text.self) { try $0.string().hasSuffix("more with news") })
    }

    /// The mockup's `trow`: the "N new" count is the chip, the reason is
    /// muted text beside it.
    func testRowShowsLatestLineCountChipAndMutedReason() throws {
        let track = card(id: 3, text: "ACME-12 · Release checklist v2", hasUpdates: true, newEvents: 3,
                         summary: "Colleague C added the rollback step.\nMore", attachment: true)
        let sut = pane([track])
        let row = try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.tracksNews.row.3")
        XCTAssertNoThrow(try row.find(text: "ACME-12 · Release checklist v2"))
        XCTAssertNoThrow(try row.find(text: "Colleague C added the rollback step."))
        XCTAssertNoThrow(try row.find(Chip.self).find(text: "3 new"))
        XCTAssertEqual(try row.findAll(Chip.self).count, 1)
        XCTAssertNoThrow(try row.find(text: "attachment"))
        XCTAssertThrowsError(try row.find(Chip.self).find(text: "attachment"), "the reason is not a chip")

        // A reason without new events: muted text, no chip.
        let reasonOnly = pane([card(id: 5, hasUpdates: true, attachment: true)])
        let quietRow = try reasonOnly.inspect().find(viewWithAccessibilityIdentifier: "inbox.tracksNews.row.5")
        XCTAssertNoThrow(try quietRow.find(text: "attachment"))
        XCTAssertThrowsError(try quietRow.find(Chip.self))

        let plain = pane([card(id: 4, hasUpdates: true)])
        let bare = try plain.inspect().find(viewWithAccessibilityIdentifier: "inbox.tracksNews.row.4")
        XCTAssertThrowsError(try bare.find(Chip.self))
        XCTAssertThrowsError(try bare.find(text: "0 new"))
    }

    func testQuietNoteButtonOnlyWithOldQuiet() throws {
        let old = pane([card(id: 1, hasUpdates: true), card(id: 2, lastEventDaysAgo: 5),
                        card(id: 3, lastEventDaysAgo: 40)])
        XCTAssertNoThrow(try old.inspect().find(
            text: "2 threads have nothing new for you. 1 of them has been quiet for over 30 days."
        ))
        XCTAssertNoThrow(try old.inspect().find(InboxBulkPressButton.self))
        XCTAssertNoThrow(try old.inspect().find(button: "Stop Tracking Quiet Ones…"))

        let recent = pane([card(id: 1, hasUpdates: true), card(id: 2, lastEventDaysAgo: 5)])
        XCTAssertNoThrow(try recent.inspect().find(text: "1 thread has nothing new for you."))
        XCTAssertThrowsError(try recent.inspect().find(InboxBulkPressButton.self))

        let allNews = pane([card(id: 1, hasUpdates: true)])
        XCTAssertThrowsError(try allNews.inspect().find(ViewType.Text.self) {
            try $0.string().contains("nothing new for you")
        })
    }

    func testConfirmTitlePluralises() throws {
        XCTAssertEqual(InboxTracksNewsPane.confirmTitle(1), "Stop Tracking 1 Thread")
        XCTAssertEqual(InboxTracksNewsPane.confirmTitle(4), "Stop Tracking 4 Threads")
    }

    /// The press runs the model's own plan and apply.
    func testStopQuietPressUsesTheModelsPlanAndApply() async throws {
        var stopped: [[String]] = []
        let model = InboxBulkPressModel(
            plan: { InboxBulkPlan(ids: ["9"], count: 1) },
            apply: { ids in
                stopped.append(ids)
                return .done(count: ids.count, skipped: 0)
            })
        let sut = InboxTracksNewsPane(
            summary: TrackThreadsSummary.build(tracks: [card(id: 9, lastEventDaysAgo: 40)], now: now),
            quietPress: model,
            onOpenThread: { _ in },
            onAllThreads: {}
        )
        try sut.inspect().find(button: "Stop Tracking Quiet Ones…").tap()
        await waitUntil { model.state == .confirming(InboxBulkPlan(ids: ["9"], count: 1)) }
        model.confirm()
        await waitUntil { model.state == .finished(.done(count: 1, skipped: 0)) }
        XCTAssertEqual(stopped, [["9"]])
    }

    func testOpeningARowCallsOnOpenThreadWithItsID() throws {
        var opened: [Int] = []
        var allThreads = 0
        let sut = pane(news(1...3), onOpenThread: { opened.append($0) }, onAllThreads: { allThreads += 1 })
        try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.tracksNews.row.2").button().tap()
        XCTAssertEqual(opened, [2])
        try sut.inspect().find(button: "All Threads").tap()
        XCTAssertEqual(allThreads, 1)
    }

    func testNoNewsShowsQuietNoteOnly() throws {
        let sut = pane([card(id: 1, lastEventDaysAgo: 5), card(id: 2, lastEventDaysAgo: 45)])
        XCTAssertEqual(try rowIDs(sut), [])
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Text.self) {
            try $0.string().hasPrefix("With news for you")
        })
        XCTAssertNoThrow(try sut.inspect().find(
            text: "2 threads have nothing new for you. 1 of them has been quiet for over 30 days."
        ))
        XCTAssertNoThrow(try sut.inspect().find(text: "Track my threads"))
        XCTAssertNoThrow(try sut.inspect().find(
            text: "0 threads with news for you · 2 quiet · scanned after every sync"
        ))
    }

    func testBackBarGoesBack() throws {
        var back = 0
        let sut = InboxTrackBackBar { back += 1 }
        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertNoThrow(try button.find(text: "Track my threads"))
        XCTAssertEqual(try button.help().string(), "Back to Track my threads")
        try button.tap()
        XCTAssertEqual(back, 1)
    }

    /// Yields until `done` holds, failing after 10 s.
    private func waitUntil(_ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out") }
            await Task.yield()
        }
    }
}
