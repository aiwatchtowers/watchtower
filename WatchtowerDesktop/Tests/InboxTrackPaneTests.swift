import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The Inbox's track card (C1 Task 9): the common row with Done and the ⋯
/// menu, a custom track's controls through the seam, the activity history
/// (new first, earlier folded), the inline scan and delete rows, and no
/// sheet, pop-up or dialog anywhere in the card.
@MainActor
final class InboxTrackPaneTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path = ""

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        manager = nil
        TestDatabase.cleanup(path: path)
    }

    /// A value the views bind to, kept across re-inspections (ViewInspector
    /// keeps no `@State` without hosting).
    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }

    private func track(custom: Bool, linked: Bool = false) throws -> Track {
        let id = try manager.dbPool.write { db -> Int in
            let target = linked
                ? try TargetQueries.create(db, text: "watched", periodStart: "2026-10-01", periodEnd: "2026-10-31")
                : nil
            let id = try TestDatabase.insertTrack(db, text: custom ? "Watch the refund" : "Launch of acme v2",
                                                  linkedTargetID: target)
            if custom {
                try db.execute(sql: """
                    UPDATE tracks SET origin = 'custom', enabled = 1, instruction = 'watch the refund decision'
                    WHERE id = ?
                    """, arguments: [id])
            }
            return Int(id)
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TrackQueries.fetchByID(db, id: id) })
    }

    private func card(_ track: Track) -> InboxTrackCard {
        InboxTrackCard(track: track, lastEventAt: Date(), newEventCount: 0)
    }

    private func timeline(
        _ track: Track, controls: (any CustomTrackControlling)? = nil
    ) -> CustomTrackTimelineViewModel {
        CustomTrackTimelineViewModel(
            track: track, dbManager: manager,
            scanService: TrackScanService(runner: FakeCLIRunner(stdout: Data("[]".utf8))),
            actionRunner: FakeCLIRunner(), controls: controls ?? RecordingCustomTrackControls(),
            scanCenter: TrackScanCenter())
    }

    private func events(_ track: Track, unread: Int, read: Int, action: String = "") throws -> [TrackEvent] {
        try manager.dbPool.write { db in
            for n in 0..<(unread + read) {
                try db.execute(sql: """
                    INSERT INTO track_events (track_id, summary, read_at, proposed_action, action_status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [track.id, n < unread ? "new \(n)" : "old \(n)",
                                     n < unread ? nil : "2026-10-20T09:00:00Z",
                                     action, action.isEmpty ? "none" : "pending",
                                     "2026-10-2\(n % 10)T08:00:00Z"])
            }
        }
        return try manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }
    }

    private func actions(
        _ track: Track,
        confirmingDelete: Box<Bool> = Box(false),
        onMakeTask: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) -> TrackCardActions {
        TrackCardActions(
            subject: InboxCardSubject(track: card(track), events: []), link: URL(string: "https://example.com/t"),
            isCustom: track.isCustom, linkedTargetID: track.linkedTargetID, navScreens: [], workbenches: [],
            isWriting: false, isMakingTask: false, confirmingDelete: confirmingDelete.binding,
            onCommand: { _ in }, onDone: {}, onStopWatching: {}, onMakeTask: onMakeTask,
            onGoToTarget: { _ in }, onDelete: onDelete)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The buttons

    func testCommonRowAndMenu() throws {
        let auto = try track(custom: false)
        var pressed: [String] = []
        let pane = InboxTrackPane(
            card: card(auto), tracks: TracksViewModel(dbManager: manager), controls: RecordingCustomTrackControls(),
            onDone: { pressed.append("done") }, onStopWatching: { pressed.append("stop") },
            onCommand: { _ in }, workbenches: []
        ).environment(AppState.isolated())

        for label in ["Discuss in Chat", "Hand to Agent…", "Done", "Stop watching", "Make a Task"] {
            XCTAssertNoThrow(try pane.inspect().find(button: label), label)
        }
        // Delete is a custom track's only.
        XCTAssertThrowsError(try pane.inspect().find(button: "Delete…"))
        try pane.inspect().find(button: "Done").tap()
        try pane.inspect().find(button: "Stop watching").tap()
        XCTAssertEqual(pressed, ["done", "stop"])

        var madeTask = false
        let makeTask = { madeTask = true }
        try actions(auto, onMakeTask: makeTask).inspect().find(button: "Make a Task").tap()
        XCTAssertTrue(madeTask)
    }

    func testDeleteAsksInline() throws {
        let custom = try track(custom: true)
        let confirming = Box(false)
        var deleted = 0
        let delete = { deleted += 1 }
        XCTAssertThrowsError(try actions(custom, confirmingDelete: confirming).inspect().find(button: "Make a Task"))
        XCTAssertThrowsError(try actions(custom, confirmingDelete: confirming).inspect()
            .find(text: "Delete — this can't be undone"))

        try actions(custom, confirmingDelete: confirming).inspect().find(button: "Delete…").tap()
        XCTAssertTrue(confirming.value)
        let row = actions(custom, confirmingDelete: confirming, onDelete: delete)
        XCTAssertNoThrow(try row.inspect().find(text: "Delete — this can't be undone"))
        try row.inspect().find(button: "Cancel").tap()
        XCTAssertFalse(confirming.value)
        XCTAssertEqual(deleted, 0)

        confirming.value = true
        try actions(custom, confirmingDelete: confirming, onDelete: delete).inspect().find(button: "Delete").tap()
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(confirming.value)
    }

    // MARK: - A custom track's controls

    func testCustomTrackControlsOnTheCard() throws {
        let custom = try track(custom: true)
        let state = Box(TrackCardState(track: custom))
        func section() -> CustomTrackControlsSection {
            CustomTrackControlsSection(track: custom, controls: RecordingCustomTrackControls(),
                                       state: state.binding) {}
        }
        XCTAssertNoThrow(try section().inspect().find(ViewType.Toggle.self))
        XCTAssertNoThrow(try section().inspect().find(text: "Collecting"))
        XCTAssertNoThrow(try section().inspect().find(text: "watch the refund decision"))
        state.value.collecting = false
        XCTAssertNoThrow(try section().inspect().find(text: "Paused"))

        XCTAssertThrowsError(try section().inspect().find(ViewType.TextField.self))
        try section().inspect().find(button: "Edit").tap()
        XCTAssertTrue(state.value.editingInstruction)
        XCTAssertEqual(state.value.draftInstruction, "watch the refund decision")
        let field = try section().inspect().find(ViewType.TextField.self)
        XCTAssertTrue(try field.textFieldStyle() is KitFieldStyle)
        XCTAssertNoThrow(try section().inspect().find(button: "Save"))
        try section().inspect().find(button: "Cancel").tap()
        XCTAssertFalse(state.value.editingInstruction)

        // Scan is an inline row with the popover's ranges, never a pop-up.
        let vm = timeline(custom)
        let scanOpen = Box(false)
        func activity() -> CustomTrackTimelineView {
            CustomTrackTimelineView(viewModel: vm, scanRowOpen: scanOpen.binding, showsEarlier: .constant(false))
        }
        XCTAssertThrowsError(try activity().inspect().find(button: "Scan from date"))
        try activity().inspect().find(button: "Scan").tap()
        XCTAssertTrue(scanOpen.value)
        for label in ["Since last check", "Last 7 days", "Last 30 days", "Last 90 days", "Since track created",
                      "All history", "Scan from date", "Cancel"] {
            XCTAssertNoThrow(try activity().inspect().find(button: label), label)
        }
        XCTAssertNoThrow(try activity().inspect().find(ViewType.DatePicker.self))
        try activity().inspect().find(button: "Cancel").tap()
        XCTAssertFalse(scanOpen.value)
    }

    func testCustomTrackControlsGoThroughTheSeam() async throws {
        let custom = try track(custom: true)
        let fake = RecordingCustomTrackControls()
        let state = Box(TrackCardState(track: custom))
        func section() -> CustomTrackControlsSection {
            CustomTrackControlsSection(track: custom, controls: fake, state: state.binding) {}
        }
        state.value.editingInstruction = true
        state.value.draftInstruction = "  watch the refund owner  "
        try section().inspect().find(button: "Save").tap()
        await waitUntil { !fake.calls.isEmpty }
        try section().inspect().find(ViewType.Toggle.self).tap()
        await waitUntil { fake.calls.count == 2 }

        let vm = timeline(custom, controls: fake)
        let scanOpen = Box(true)
        try CustomTrackTimelineView(viewModel: vm, scanRowOpen: scanOpen.binding, showsEarlier: .constant(false))
            .inspect().find(button: "Scan from date").tap()
        XCTAssertFalse(scanOpen.value, "the row closes when the scan starts")
        await waitUntil { fake.calls.count == 3 }

        let strip = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), customTrackControls: fake,
                                         defaults: try XCTUnwrap(UserDefaults(suiteName: "InboxTrackPaneTests")))
        await strip.stopWatching(custom)

        XCTAssertEqual(fake.calls.count, 4)
        XCTAssertEqual(Array(fake.calls.prefix(2)), [
            .saveInstruction(trackID: custom.id, text: "watch the refund owner"),
            .setCollecting(trackID: custom.id, on: false)
        ])
        guard case .scan(let trackID, _) = fake.calls[2] else { return XCTFail("\(fake.calls[2]) is not a scan") }
        XCTAssertEqual(trackID, custom.id)
        XCTAssertEqual(fake.calls[3], .stopWatching(trackID: custom.id))
        // The card reflects the writes the seam accepted, and the database is
        // untouched: nothing but the seam wrote.
        XCTAssertEqual(state.value.instruction, "watch the refund owner")
        XCTAssertFalse(state.value.collecting)
        XCTAssertFalse(state.value.editingInstruction)
        let fetched = try manager.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT instruction, enabled, dismissed_at FROM tracks WHERE id = ?",
                             arguments: [custom.id])
        }
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row["instruction"] as String?, "watch the refund decision")
        XCTAssertEqual(row["enabled"] as Int?, 1)
        XCTAssertEqual(row["dismissed_at"] as String?, "")
    }

    /// A refused write keeps the editor open with the draft and says why.
    func testAFailedSaveKeepsTheDraft() async throws {
        let custom = try track(custom: true)
        let fake = RecordingCustomTrackControls()
        fake.failure = RowNotFoundError(kind: "track", id: custom.id)
        let state = Box(TrackCardState(track: custom))
        state.value.editingInstruction = true
        state.value.draftInstruction = "new text"
        var gone = 0
        let section = CustomTrackControlsSection(track: custom, controls: fake, state: state.binding) { gone += 1 }

        await section.save()

        XCTAssertTrue(state.value.editingInstruction)
        XCTAssertEqual(state.value.draftInstruction, "new text")
        XCTAssertEqual(state.value.instruction, "watch the refund decision")
        XCTAssertTrue(state.value.watchEditError?.hasPrefix("Failed to save the instruction") ?? false)
        XCTAssertEqual(gone, 1)
    }

    // MARK: - The history

    func testNewSinceYouLookedThenEarlierFolded() throws {
        let custom = try track(custom: true)
        let vm = timeline(custom)
        vm.events = try events(custom, unread: 2, read: 5)
        let showsEarlier = Box(false)
        func activity() -> CustomTrackTimelineView {
            CustomTrackTimelineView(viewModel: vm, scanRowOpen: .constant(false), showsEarlier: showsEarlier.binding)
        }

        XCTAssertNoThrow(try activity().inspect().find(text: "New since you looked"))
        for n in 0..<2 {
            XCTAssertNoThrow(try activity().inspect().find(text: "new \(n)"))
        }
        XCTAssertNoThrow(try activity().inspect().find(text: "Earlier · 5"))
        for n in 2..<7 {
            XCTAssertThrowsError(try activity().inspect().find(text: "old \(n)"), "folded")
        }

        try activity().inspect().find(button: "Show all").tap()
        XCTAssertTrue(showsEarlier.value)
        for n in 2..<7 {
            XCTAssertNoThrow(try activity().inspect().find(text: "old \(n)"))
        }
        XCTAssertThrowsError(try activity().inspect().find(button: "Show all"))
    }

    /// With nothing new the earlier events are all there is, so they show.
    func testNothingNewShowsTheEarlierEvents() throws {
        let custom = try track(custom: true)
        let vm = timeline(custom)
        vm.events = try events(custom, unread: 0, read: 2)
        let sut = CustomTrackTimelineView(viewModel: vm, scanRowOpen: .constant(false), showsEarlier: .constant(false))

        XCTAssertThrowsError(try sut.inspect().find(text: "New since you looked"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Earlier · 2"))
        XCTAssertNoThrow(try sut.inspect().find(text: "old 0"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Show all"))
    }

    func testApplyShowsOnlyForALinkedTrack() throws {
        let action = #"{"type":"add_sub_item","reason":"a reason","text":"x"}"#
        for linked in [true, false] {
            let custom = try track(custom: true, linked: linked)
            let vm = timeline(custom)
            vm.events = try events(custom, unread: 1, read: 0, action: action)
            let sut = CustomTrackTimelineView(viewModel: vm, scanRowOpen: .constant(false),
                                              showsEarlier: .constant(false))

            XCTAssertNoThrow(try sut.inspect().find(button: "Dismiss"), "linked: \(linked)")
            if linked {
                XCTAssertNoThrow(try sut.inspect().find(button: "Apply"))
            } else {
                XCTAssertThrowsError(try sut.inspect().find(button: "Apply"))
            }
        }
    }

    // MARK: - Make a Task

    func testMakeATaskCreatesTheTargetAndOpensIt() async throws {
        let auto = try track(custom: false)
        let appState = AppState.isolated()
        appState.databaseManager = manager

        let failure = await appState.makeTask(fromTrack: auto)

        XCTAssertNil(failure)
        let fetched = try manager.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT id, text, source_type, source_id FROM targets WHERE source_type = 'track'")
        }
        let target = try XCTUnwrap(fetched)
        XCTAssertEqual(target["source_id"] as String?, String(auto.id))
        XCTAssertFalse(((target["text"] as String?) ?? "").isEmpty)
        XCTAssertEqual(appState.pendingTargetID, target["id"] as Int?)
        XCTAssertEqual(appState.selectedDestination, .targets)
    }

    // MARK: - No pop-ups

    /// The card, its controls and its history carry no sheet, pop-up or
    /// dialog (C1: in-panel only). ViewInspector cannot see an unpresented
    /// sheet or popover, so the card's source files are read; the only
    /// pop-up the card reaches is the common row's workbench picker, in
    /// `InboxCommonRow.swift`, the style guide's anchored-picker exception.
    func testNoSheetOrPopoverModifiers() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        let files = ["Inbox/InboxTrackPane.swift", "Tracks/TrackDetailView.swift", "Tracks/CustomTrackTimelineView.swift"]
        for file in files {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            for modifier in [".sheet(", ".popover(", ".confirmationDialog(", ".alert(", ".fullScreenCover("] {
                XCTAssertFalse(source.contains(modifier), "\(file) uses \(modifier)")
            }
        }

        let custom = try track(custom: true)
        let pane = InboxTrackPane(
            card: card(custom), tracks: TracksViewModel(dbManager: manager), controls: RecordingCustomTrackControls(),
            onDone: {}, onStopWatching: {}, onCommand: { _ in }, workbenches: []
        ).environment(AppState.isolated())
        XCTAssertNoThrow(try pane.inspect().find(button: "Delete…"))
        XCTAssertTrue(try pane.inspect().findAll(ViewType.Sheet.self).isEmpty)
    }
}
