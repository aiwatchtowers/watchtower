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
        onRestore: @escaping () -> Void = {},
        onMakeTask: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) -> TrackCardActions {
        TrackCardActions(
            subject: InboxCardSubject(track: card(track), events: []), link: URL(string: "https://example.com/t"),
            isCustom: track.isCustom, isStopped: track.isDismissed, linkedTargetID: track.linkedTargetID,
            navScreens: [], workbenches: [], isWriting: false, isMakingTask: false,
            confirmingDelete: confirmingDelete.binding, onCommand: { _ in }, onDone: {}, onStopWatching: {},
            onRestore: onRestore, onMakeTask: onMakeTask, onGoToTarget: { _ in }, onDelete: onDelete)
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
            onDone: { pressed.append("done") }, onStopWatching: { pressed.append("stop") }, onRestore: {},
            onCommand: { _ in }, workbenches: []
        ).environment(AppState.isolated())

        for label in ["Discuss in Chat", "Hand to Agent…", "Done", "Stop watching", "Make a Task"] {
            XCTAssertNoThrow(try pane.inspect().find(button: label), label)
        }
        // Delete is a custom track's only.
        XCTAssertThrowsError(try pane.inspect().find(button: "Delete…"))
        XCTAssertThrowsError(try pane.inspect().find(button: "Restore"), "only a stopped track restores")
        try pane.inspect().find(button: "Done").tap()
        try pane.inspect().find(button: "Stop watching").tap()
        XCTAssertEqual(pressed, ["done", "stop"])

        var madeTask = false
        let makeTask = { madeTask = true }
        try actions(auto, onMakeTask: makeTask).inspect().find(button: "Make a Task").tap()
        XCTAssertTrue(madeTask)
    }

    /// The chat starts folded under **Open chat**, so the card's own buttons
    /// are not pushed below the fold by it.
    func testChatStartsFolded() throws {
        let pane = InboxTrackPane(
            card: card(try track(custom: false)), tracks: TracksViewModel(dbManager: manager),
            controls: RecordingCustomTrackControls(), onDone: {}, onStopWatching: {}, onRestore: {},
            onCommand: { _ in }, workbenches: []
        ).environment(AppState.isolated())

        XCTAssertNoThrow(try pane.inspect().find(button: "Open chat"))
        XCTAssertThrowsError(try pane.inspect().find(TrackChatSection.self))
        XCTAssertThrowsError(try pane.inspect().find(ViewType.VSplitView.self))
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
        func activity() -> CustomTrackTimelineView {
            CustomTrackTimelineView(viewModel: vm, scanRowOpen: scanOpen.binding, showsEarlier: .constant(false))
        }
        try activity().inspect().find(button: "Since last check").tap()
        XCTAssertFalse(scanOpen.value, "the row closes when the scan starts")
        await waitUntil { fake.calls.count == 3 }
        await waitUntil { !vm.isRefreshing }
        scanOpen.value = true
        // The date picker starts a week back.
        let weekAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -7, to: Date()))
        try activity().inspect().find(button: "Scan from date").tap()
        await waitUntil { fake.calls.count == 4 }

        let suite = "InboxTrackPaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let strip = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), customTrackControls: fake,
                                         defaults: defaults)
        await strip.stopWatching(custom)
        await strip.restoreTrack(custom)

        XCTAssertEqual(fake.calls.count, 6)
        XCTAssertEqual(Array(fake.calls.prefix(3)), [
            .saveInstruction(trackID: custom.id, text: "watch the refund owner"),
            .setCollecting(trackID: custom.id, on: false),
            .scan(trackID: custom.id, from: nil)
        ])
        guard case let .scan(trackID, from?) = fake.calls[3] else {
            return XCTFail("\(fake.calls[3]) is not a scan from a date")
        }
        XCTAssertEqual(trackID, custom.id)
        XCTAssertEqual(from.timeIntervalSince1970, weekAgo.timeIntervalSince1970, accuracy: 60)
        XCTAssertEqual(Array(fake.calls.suffix(2)), [
            .stopWatching(trackID: custom.id), .resumeWatching(trackID: custom.id)
        ])
        // The card reflects the writes the seam accepted, and the database is
        // untouched: nothing but the seam wrote.
        XCTAssertEqual(state.value.instruction, "watch the refund owner")
        XCTAssertFalse(state.value.collecting)
        XCTAssertFalse(state.value.editingInstruction)
        let fetched = try await manager.dbPool.read { db in
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
        let fetched = try await manager.dbPool.read { db in
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
            onDone: {}, onStopWatching: {}, onRestore: {}, onCommand: { _ in }, workbenches: []
        ).environment(AppState.isolated())
        // The pane renders; the source scan above is the real guard.
        XCTAssertNoThrow(try pane.inspect().find(button: "Delete…"))
    }

    // MARK: - Restore

    /// A stopped track's card offers Restore in Done's place and no Stop
    /// watching; Restore reaches the card's callback.
    func testAStoppedCardRestores() throws {
        for custom in [false, true] {
            let stopped = try track(custom: custom)
            try manager.dbPool.write { db in try TrackQueries.dismiss(db, id: stopped.id) }
            let fetched = try manager.dbPool.read { db in try TrackQueries.fetchByID(db, id: stopped.id) }
            let track = try XCTUnwrap(fetched)
            XCTAssertTrue(track.isDismissed)
            var restored = 0
            let restore = { restored += 1 }
            let sut = actions(track, onRestore: restore)

            XCTAssertThrowsError(try sut.inspect().find(button: "Done"))
            XCTAssertThrowsError(try sut.inspect().find(button: "Stop watching"))
            try sut.inspect().find(button: "Restore").tap()
            XCTAssertEqual(restored, 1, "custom: \(custom)")
        }
    }

    // MARK: - Through the watch recipe (C3)

    private static func watchJSON(templateShaped: Bool = true) -> Data {
        Data(#"""
            {"watch":{"track_id":1,"instruction":"watch the refund owner","template_shaped":\#(templateShaped)},
             "run_id":3,"coalesced":false,"daemon_running":true,"at_next_sync":true,"track_id":1,"automation_id":42}
            """#.utf8)
    }

    private func bind(_ track: Track, to automationID: Int64?) throws -> Track {
        try manager.dbPool.write { db in
            try db.execute(sql: "UPDATE tracks SET automation_id = ? WHERE id = ?", arguments: [automationID, track.id])
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TrackQueries.fetchByID(db, id: track.id) })
    }

    /// C3's seam (`AppState.customTrackControls`) over a fake CLI.
    private func recipeControls(_ runner: FakeCLIRunner) -> RecipeCustomTrackControls {
        RecipeCustomTrackControls(
            cli: AutomationsCLI(runner: runner),
            direct: DirectCustomTrackControls(dbPool: manager.dbPool, scanService: TrackScanService(runner: runner)))
    }

    private func watch(_ track: Track, runner: FakeCLIRunner) -> WatchTrackControls {
        WatchTrackControls(track: track, cli: AutomationsCLI(runner: runner), controls: recipeControls(runner),
                           reader: manager.dbPool)
    }

    private func trackRow(_ id: Int) throws -> Row {
        try XCTUnwrap(manager.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT enabled, instruction, dismissed_at, automation_id FROM tracks WHERE id = ?",
                             arguments: [id])
        })
    }

    /// A bound track's Collecting flips its recipe (`automations disable`)
    /// and its scan is queued for the next sync; nothing writes `tracks`.
    func testBoundTrackControlsUseRecipe() async throws {
        let bound = try bind(try track(custom: true), to: 42)
        let runner = FakeCLIRunner(stdout: Self.watchJSON())
        let model = watch(bound, runner: runner)
        await model.load()
        let state = Box(TrackCardState(track: bound))
        state.value.instruction = model.instructionDraft
        func section() -> WatchTrackSection { WatchTrackSection(watch: model, state: state.binding) { _ in } }

        XCTAssertEqual(TrackWatchMode.of(isBound: model.isBound, moveDone: false), .watched)
        XCTAssertNoThrow(try section().inspect().find(text: "Collecting"))
        XCTAssertNoThrow(try section().inspect().find(text: "watch the refund owner"))
        XCTAssertNoThrow(try section().inspect().find(button: "Edit"))
        try section().inspect().find(ViewType.Toggle.self).tap()
        await waitUntil { !model.collecting }
        XCTAssertNoThrow(try section().inspect().find(text: "Paused"))

        let vm = timeline(bound, controls: recipeControls(runner))
        await vm.scanSinceLast()
        XCTAssertEqual(vm.lastScanNote, WatchTrackControls.nextSyncNote)
        await vm.scanHistory(since: nil, label: "all history")
        XCTAssertEqual(vm.lastScanNote, WatchTrackControls.nextSyncNote)

        XCTAssertEqual(runner.invocations, [
            ["automations", "show", "42", "--json"],
            ["automations", "disable", "42"],
            ["automations", "run", "42", "--json"],
            ["automations", "run", "42", "--since", "1970-01-01T00:00:00Z", "--json"]
        ])
        let row = try trackRow(bound.id)
        XCTAssertEqual(row["enabled"] as Int?, 1, "the SQL trigger mirrors enabled, never Swift")
        XCTAssertEqual(row["instruction"] as String?, "watch the refund decision")
    }

    /// A watch changed in the chat: the instruction is read-only, with the
    /// line and **Edit in Chat** on its recipe.
    func testEditedWatchShowsEditInChat() async throws {
        let bound = try bind(try track(custom: true), to: 42)
        let model = watch(bound, runner: FakeCLIRunner(stdout: Self.watchJSON(templateShaped: false)))
        await model.load()
        let state = Box(TrackCardState(track: bound))
        state.value.instruction = model.instructionDraft
        var edited: [Int64] = []
        let sut = WatchTrackSection(watch: model, state: state.binding) { edited.append($0) }

        XCTAssertNoThrow(try sut.inspect().find(text: "This watch was changed in the chat — change it there."))
        XCTAssertNoThrow(try sut.inspect().find(text: "watch the refund owner"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Edit"))
        XCTAssertThrowsError(try sut.inspect().find(ViewType.TextField.self))
        try sut.inspect().find(button: "Edit in Chat").tap()
        XCTAssertEqual(edited, [42])

        // A refusal's own words show on the card, the draft kept.
        let refusal = "This watch was changed in the chat — change it there."
        let refusing = watch(bound, runner: FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: refusal)))
        refusing.instructionDraft = "watch the refund window"
        state.value.editingInstruction = true
        await WatchTrackSection(watch: refusing, state: state.binding) { _ in }.save()
        XCTAssertEqual(refusing.error, refusal)
        XCTAssertTrue(state.value.editingInstruction)
        XCTAssertEqual(refusing.instructionDraft, "watch the refund window")
    }

    /// An unbound custom track: C1's controls before the custom-tracks move
    /// (or after a failed one), "Not watched yet." with **Start Watching**
    /// once it is done.
    func testUnboundTrackShowsStartWatching() async throws {
        let unbound = try track(custom: true)
        func moveDone() throws -> Bool {
            try manager.dbPool.read { try BuiltinUpgradeNotice.isMoveDone($0, id: BuiltinUpgradeNotice.customTracksID) }
        }
        XCTAssertFalse(try moveDone(), "no row: not moved yet")
        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO builtin_migrations (builtin_id, status, error, updated_at)
                VALUES ('custom-tracks', 'failed', 'disk full', '2026-10-22T08:00:00Z')
                """)
        }
        XCTAssertFalse(try moveDone(), "a failed move keeps the legacy path")
        XCTAssertEqual(TrackWatchMode.of(isBound: false, moveDone: try moveDone()), .legacy)
        try await manager.dbPool.write { db in
            try db.execute(sql: "UPDATE builtin_migrations SET status = 'done', error = '' WHERE builtin_id = 'custom-tracks'")
        }
        XCTAssertTrue(try moveDone())
        XCTAssertEqual(TrackWatchMode.of(isBound: false, moveDone: true), .notWatched)
        XCTAssertEqual(TrackWatchMode.of(isBound: true, moveDone: false), .watched)

        // Before the move the card keeps C1's controls exactly (the legacy scan runs).
        let legacy = CustomTrackControlsSection(track: unbound, controls: RecordingCustomTrackControls(),
                                                state: .constant(TrackCardState(track: unbound))) {}
        XCTAssertNoThrow(try legacy.inspect().find(text: "Collecting"))

        // After it: Start Watching binds the track through `tracks start`.
        let runner = FakeCLIRunner(stdout: Self.watchJSON())
        let pool = manager.dbPool
        let trackID = unbound.id
        runner.onRun = { args in
            guard args.prefix(2) == ["tracks", "start"] else { return }
            try? await pool.write { db in
                try db.execute(sql: "UPDATE tracks SET automation_id = 42 WHERE id = ?", arguments: [trackID])
            }
        }
        let model = watch(unbound, runner: runner)
        var started = 0
        let row = NotWatchedRow(watch: model) { started += 1 }
        XCTAssertNoThrow(try row.inspect().find(text: "Not watched yet."))
        XCTAssertNoThrow(try row.inspect().find(button: "Start Watching"))
        let activity = CustomTrackTimelineView(viewModel: timeline(unbound), scanRowOpen: .constant(false),
                                               showsEarlier: .constant(false), canScan: false)
        XCTAssertThrowsError(try activity.inspect().find(button: "Scan"), "nothing scans an unwatched track")

        await row.start()

        XCTAssertEqual(started, 1)
        XCTAssertTrue(model.isBound)
        XCTAssertEqual(runner.invocations.first, ["tracks", "start", String(trackID), "--json"])
        XCTAssertEqual(TrackWatchMode.of(isBound: model.isBound, moveDone: true), .watched)

        // A refused start says why and the track keeps Start Watching.
        let refusal = "Track my threads needs Slack Digests on"
        let other = try track(custom: true)
        let refused = watch(other, runner: FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: refusal)))
        var none = 0
        let refusedRow = NotWatchedRow(watch: refused) { none += 1 }
        await refusedRow.start()
        XCTAssertEqual(none, 0)
        XCTAssertFalse(refused.isBound)
        XCTAssertNoThrow(try refusedRow.inspect().find(text: refusal))
    }

    /// Stop watching (⋯) of a bound track through the Inbox: the recipe off
    /// (`automations disable`) and the track dismissed; `tracks.enabled` is
    /// the SQL trigger's, never written from Swift.
    func testStopWatchingBoundDisablesRecipe() async throws {
        let bound = try bind(try track(custom: true), to: 42)
        let runner = FakeCLIRunner()
        let suite = "InboxTrackPaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let strip = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(),
                                         customTrackControls: recipeControls(runner), defaults: defaults)

        await strip.stopWatching(bound)

        XCTAssertNil(strip.lastError)
        XCTAssertEqual(runner.invocations, [["automations", "disable", "42"]])
        let row = try trackRow(bound.id)
        XCTAssertNotEqual(row["dismissed_at"] as String?, "")
        XCTAssertEqual(row["enabled"] as Int?, 1)
    }
}
