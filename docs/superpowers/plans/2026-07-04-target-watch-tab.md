# Target "Watch" Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Watch" tab to the target detail that shows a unified activity feed from all the target's watches, lets you manage those watches inline, applies confirmable actions to the target, and feeds the watch activity into the target Assistant.

**Architecture:** Desktop-only SwiftUI + GRDB. A new `TargetWatchesViewModel` observes the target's watches (`tracks.linked_target_id`) and their merged events (`track_events` joined on `linked_target_id`). A new `TargetWatchTabView` renders a management strip + activity feed. The target Assistant's Swift-built system prompt gains a `=== WATCH ACTIVITY ===` block, and feed events can be pushed into the chat via `chatVM.inputText`. Reuses existing `TrackScanService`, `TrackScanCenter`, `TargetActionExecutor`, `TrackQueries`, `TrackEventQueries`, `CustomTrackManagementSheet`.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14+), GRDB.swift, Swift Testing / XCTest (existing suite in `WatchtowerDesktop/Tests`).

## Global Constraints

- **Desktop-only.** No Go, CLI, `internal/db/schema.sql`, or goose migration changes. Everything reuses existing tables (`tracks`, `track_events`) and executors.
- Build: `cd WatchtowerDesktop && swift build`. Tests: `cd WatchtowerDesktop && swift test` (92 tests currently green — keep them green).
- `@MainActor @Observable` view models; GRDB `ValueObservation` for reactive reads; writes via `dbPool.write`.
- A `@MainActor`-isolated type (e.g. `TargetsViewModel`, `TrackScanCenter`) cannot be constructed in a default argument expression — pass such dependencies explicitly (learned: default-arg init runs in a nonisolated context).
- Follow the existing MVVM shape: Models → Queries (`enum XQueries` static funcs) → ViewModels (`@Observable`) → Views.
- All user-facing copy in English.

## File Structure

- **Create** `WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift` — owns watches/originTrack/events + scan/apply/dismiss/toggle/delete.
- **Create** `WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift` — the tab UI (management strip + feed + event row).
- **Create** `WatchtowerDesktop/Tests/TargetWatchesViewModelTests.swift` — VM + query tests.
- **Modify** `WatchtowerDesktop/Sources/Database/Queries/TrackEventQueries.swift` — add `fetchForTarget`.
- **Modify** `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift` — add `Tab.watch`, switch arm, tab VM lifecycle; remove the Details `watchesSection` + `loadLinkedWatches`; wire the Discuss action.
- **Modify** `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift` — add `watchActivityBlock` and inject it in `buildSystemPrompt`.

---

## Task 1: `fetchForTarget` query + `TargetWatchesViewModel` foundation

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/TrackEventQueries.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift`
- Create: `WatchtowerDesktop/Tests/TargetWatchesViewModelTests.swift`

**Interfaces:**
- Consumes: `TrackEvent`, `Track`, `TrackQueries.fetchByLinkedTarget(_:targetID:)`, `TrackQueries.fetchByID(_:id:)`, `DatabaseManager.dbPool`, `TrackScanCenter`, `TargetsViewModel`, `TrackScanService`.
- Produces:
  - `TrackEventQueries.fetchForTarget(_ db: Database, targetID: Int, limit: Int = 200) throws -> [TrackEvent]`
  - `final class TargetWatchesViewModel` with `watches: [Track]`, `originTrack: Track?`, `events: [TrackEvent]`, `errorMessage: String?`, `func start()`, `func stop()`, `func watchName(for trackID: Int) -> String`.

- [ ] **Step 1: Write the failing test** — `WatchtowerDesktop/Tests/TargetWatchesViewModelTests.swift`. Model the harness on `CustomTrackTimelineViewModelTests` (it already has `Self.trackEventsSQL` and `TestDatabase`). Copy that file's `trackEventsSQL` static constant into this test too (or reference it — keep it self-contained by re-declaring):

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TargetWatchesViewModelTests: XCTestCase {

    // Mirrors the track_events DDL the CustomTrackTimeline tests use, so the
    // test DB has the table the app schema creates at runtime.
    static let trackEventsSQL = """
        CREATE TABLE IF NOT EXISTS track_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            summary TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '',
            source_type TEXT NOT NULL DEFAULT '', source_id TEXT NOT NULL DEFAULT '',
            source_refs TEXT NOT NULL DEFAULT '[]', decision TEXT NOT NULL DEFAULT '',
            proposed_action TEXT NOT NULL DEFAULT '',
            action_status TEXT NOT NULL DEFAULT 'none',
            read_at TEXT, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        );
        """

    private func makeWatch(_ db: Database, targetID: Int?, text: String) throws -> Int {
        try db.execute(sql: """
            INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                origin, instruction, enabled, linked_target_id)
            VALUES ('U1', ?, '', 'task', 'watching', 'medium', 'custom', 'watch', 1, ?)
            """, arguments: [text, targetID])
        return Int(db.lastInsertedRowID)
    }

    func testFetchForTargetScopesToTargetsWatches() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try db.execute(sql: Self.trackEventsSQL) }

        let t1 = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal one", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let t2 = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal two", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        try manager.dbPool.write { db in
            let w1 = try makeWatch(db, targetID: t1, text: "watch A")
            let w2 = try makeWatch(db, targetID: t2, text: "watch B")
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'a1', '2026-06-10T00:00:00Z')", arguments: [w1])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'a2', '2026-06-11T00:00:00Z')", arguments: [w1])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'b1', '2026-06-12T00:00:00Z')", arguments: [w2])
        }
        let events = try manager.dbPool.read { db in
            try TrackEventQueries.fetchForTarget(db, targetID: t1)
        }
        XCTAssertEqual(events.map(\.summary), ["a2", "a1"], "only t1's watch events, newest-first")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TargetWatchesViewModelTests 2>&1 | tail -20`
Expected: FAIL — `fetchForTarget` does not exist (compile error).

- [ ] **Step 3: Add `fetchForTarget`** to `TrackEventQueries.swift` (after `fetchEvents`):

```swift
    /// Merged timeline across all of a target's watches (custom tracks linked to
    /// it), newest-first. Reactive to inserts and to watch deletion (FK cascade).
    static func fetchForTarget(_ db: Database, targetID: Int, limit: Int = 200) throws -> [TrackEvent] {
        try TrackEvent.fetchAll(db, sql: """
            SELECT e.* FROM track_events e
            JOIN tracks t ON t.id = e.track_id
            WHERE t.linked_target_id = ?
            ORDER BY e.created_at DESC, e.id DESC
            LIMIT ?
            """, arguments: [targetID, limit])
    }
```

- [ ] **Step 4: Run to verify the query test passes**

Run: `cd WatchtowerDesktop && swift test --filter TargetWatchesViewModelTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Create `TargetWatchesViewModel.swift`** (foundation — data + observation; actions come in Task 2):

```swift
import Foundation
import GRDB

/// Drives the target's "Watch" tab: the watches linked to the target, the
/// origin track it was promoted from (if any), and the merged activity feed
/// from all its watches. Applies a confirmed proposed action to THIS target.
@MainActor
@Observable
final class TargetWatchesViewModel {
    let target: Target
    private let dbPool: DatabasePool
    private let scanCenter: TrackScanCenter
    private let targetsViewModel: TargetsViewModel
    private let scanService: TrackScanService

    var watches: [Track] = []
    var originTrack: Track?
    var events: [TrackEvent] = []
    var errorMessage: String?

    private var watchesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    init(target: Target,
         dbManager: DatabaseManager,
         scanService: TrackScanService,
         targetsViewModel: TargetsViewModel,
         scanCenter: TrackScanCenter) {
        self.target = target
        self.dbPool = dbManager.dbPool
        self.scanService = scanService
        self.targetsViewModel = targetsViewModel
        self.scanCenter = scanCenter
    }

    /// Human label for a feed event's source watch.
    func watchName(for trackID: Int) -> String {
        watches.first { $0.id == trackID }?.text ?? "Watch"
    }

    func start() {
        loadOriginTrack()
        let id = target.id
        let pool = dbPool
        watchesTask?.cancel()
        watchesTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try TrackQueries.fetchByLinkedTarget(db, targetID: id)
            }
            do {
                for try await rows in obs.values(in: pool) {
                    guard let self else { return }
                    self.watches = rows
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            let obs = ValueObservation.tracking { db in
                try TrackEventQueries.fetchForTarget(db, targetID: id)
            }
            do {
                for try await rows in obs.values(in: pool) {
                    guard let self else { return }
                    self.events = rows
                }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        watchesTask?.cancel(); watchesTask = nil
        eventsTask?.cancel(); eventsTask = nil
    }

    private func loadOriginTrack() {
        guard target.sourceType == "track", let tid = Int(target.sourceId) else {
            originTrack = nil
            return
        }
        originTrack = try? dbPool.read { db in try TrackQueries.fetchByID(db, id: tid) }
    }
}
```

> Verify the property names `target.sourceType` / `target.sourceId` against `Sources/Models/Target.swift` (grep `sourceType`/`sourceId`); adapt if they differ (e.g. `source_type` column mapped to a different Swift name).

- [ ] **Step 6: Build to verify the VM compiles**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -15`
Expected: Build complete.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Database/Queries/TrackEventQueries.swift \
        WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift \
        WatchtowerDesktop/Tests/TargetWatchesViewModelTests.swift
git commit -m "feat(desktop): target watch feed query + TargetWatchesViewModel foundation"
```

---

## Task 2: VM actions — scan, apply, dismiss, toggle, delete, markRead

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift`
- Modify: `WatchtowerDesktop/Tests/TargetWatchesViewModelTests.swift`

**Interfaces:**
- Consumes: `TrackScanCenter.begin/finish`, `TrackScanService.run(trackID:since:)`, `TargetActionExecutor.apply(_:target:viewModel:)`, `TargetQueries.fetchByID`, `TrackEventQueries.setActionStatus/markRead`, `TrackQueries.setEnabled/delete`.
- Produces on `TargetWatchesViewModel`:
  - `func isScanning(_ trackID: Int) -> Bool`
  - `func scanWatch(_ watch: Track, since: Date?, label: String) async`
  - `func scanAll() async`
  - `var canApplyActions: Bool` (always true here — every feed event is from a linked watch)
  - `func applyAction(for event: TrackEvent)`
  - `func dismissAction(for event: TrackEvent)`
  - `func markRead(_ event: TrackEvent)`
  - `func setCollecting(_ watch: Track, _ on: Bool)`
  - `func deleteWatch(_ watch: Track)`

- [ ] **Step 1: Write the failing test** (append to `TargetWatchesViewModelTests.swift`). It seeds a target + a linked watch + a pending `update_status` event, then asserts `applyAction` changes the target status and marks the event applied. Mirror the apply harness from `CustomTrackTimelineViewModelTests` (which builds a `TargetsViewModel` and a `FakeCLIRunner`):

```swift
    func testApplyActionMutatesTargetAndMarksApplied() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try db.execute(sql: Self.trackEventsSQL) }

        let targetID = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "ship it", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let (watchID, eventID) = try manager.dbPool.write { db -> (Int, Int) in
            let w = try makeWatch(db, targetID: targetID, text: "watch ship")
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, proposed_action, action_status)
                VALUES (?, 'done', ?, 'pending')
                """, arguments: [w, #"{"type":"update_status","reason":"shipped","status":"done"}"#])
            return (w, Int(db.lastInsertedRowID))
        }
        _ = watchID

        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID) })
        let vm = TargetWatchesViewModel(
            target: target,
            dbManager: manager,
            scanService: TrackScanService(runner: FakeCLIRunner(stdout: Data("[]".utf8))),
            targetsViewModel: TargetsViewModel(dbManager: manager),
            scanCenter: TrackScanCenter()
        )
        let event = try XCTUnwrap(manager.dbPool.read { db in
            try TrackEvent.fetchOne(db, sql: "SELECT * FROM track_events WHERE id = ?", arguments: [eventID])
        })
        vm.applyAction(for: event)

        let status = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [targetID])
        }
        XCTAssertEqual(status, "done")
        let evStatus = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events WHERE id = ?", arguments: [eventID])
        }
        XCTAssertEqual(evStatus, "applied")
    }
```

> If `FakeCLIRunner`'s initializer label differs (e.g. `stdout:` vs `output:`), match the one in `CustomTrackTimelineViewModelTests`. Reuse the exact `TargetActionExecutor.apply` call shape from `CustomTrackTimelineViewModel.applyAction`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TargetWatchesViewModelTests 2>&1 | tail -20`
Expected: FAIL — `applyAction` not defined.

- [ ] **Step 3: Add the action methods** to `TargetWatchesViewModel`:

```swift
    // MARK: - Scanning

    func isScanning(_ trackID: Int) -> Bool { scanCenter.isRunning(trackID) }

    /// Scans one watch over the given range (nil since = all history), tracked
    /// in the shared center so the indicator survives navigation.
    func scanWatch(_ watch: Track, since: Date?, label: String) async {
        scanCenter.begin(watch.id)
        var note: String?
        defer { scanCenter.finish(watch.id, note: note) }
        do {
            let iso = since.map { Self.isoFormatter.string(from: $0) }
            let created = try await scanService.run(trackID: watch.id, since: iso)
            note = created.isEmpty
                ? "\(watch.text): no new activity (\(label))."
                : "\(watch.text): \(created.count) new update(s)."
        } catch {
            note = "\(watch.text): scan failed — \(error.localizedDescription)"
            errorMessage = error.localizedDescription
        }
    }

    /// Scans every enabled watch of the target (concurrently is unnecessary —
    /// each is a slow subprocess; run them in sequence to keep it simple).
    func scanAll() async {
        for w in watches where w.enabled {
            await scanWatch(w, since: nil, label: "all history")
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Feed actions

    /// Every feed event originates from a watch linked to this target, so a
    /// confirmed proposed action always has a target to mutate.
    var canApplyActions: Bool { true }

    func applyAction(for event: TrackEvent) {
        guard let action = event.decodedAction else { return }
        do {
            guard let fresh = try dbPool.read({ db in try TargetQueries.fetchByID(db, id: target.id) }) else {
                errorMessage = "This target no longer exists — it may have been deleted."
                return
            }
            _ = try TargetActionExecutor.apply(action, target: fresh, viewModel: targetsViewModel)
            try dbPool.write { db in try TrackEventQueries.setActionStatus(db, id: event.id, status: "applied") }
        } catch { errorMessage = error.localizedDescription }
    }

    func dismissAction(for event: TrackEvent) {
        do { try dbPool.write { db in try TrackEventQueries.setActionStatus(db, id: event.id, status: "dismissed") } }
        catch { errorMessage = error.localizedDescription }
    }

    func markRead(_ event: TrackEvent) {
        guard event.isUnread else { return }
        try? dbPool.write { db in try TrackEventQueries.markRead(db, id: event.id) }
    }

    // MARK: - Watch management

    func setCollecting(_ watch: Track, _ on: Bool) {
        try? dbPool.write { db in try TrackQueries.setEnabled(db, id: watch.id, enabled: on) }
    }

    func deleteWatch(_ watch: Track) {
        try? dbPool.write { db in try TrackQueries.delete(db, id: watch.id) }
    }
```

> Confirm `TargetActionExecutor.apply` returns something ignorable and takes `(action, target:, viewModel:)` — copy the exact call from `CustomTrackTimelineViewModel.applyAction`. Confirm `TrackEvent.decodedAction` / `isUnread` exist (they do — used by the timeline row).

- [ ] **Step 4: Run to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter TargetWatchesViewModelTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift \
        WatchtowerDesktop/Tests/TargetWatchesViewModelTests.swift
git commit -m "feat(desktop): TargetWatchesViewModel scan/apply/dismiss/manage actions"
```

---

## Task 3: `TargetWatchTabView` + wire `Tab.watch`, remove Details watches section

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift`

**Interfaces:**
- Consumes: `TargetWatchesViewModel`, `CustomTrackManagementSheet`, `appState.trackScanCenter`, `appState.navigateToTrack`, `TrackScanService`, `ProcessCLIRunner.makeDefault()`.
- Produces: `struct TargetWatchTabView: View` (init `TargetWatchTabView(viewModel:onDiscuss:)`), and a `.watch` case on `TargetDetailView.Tab`.

- [ ] **Step 1: Create `TargetWatchTabView.swift`**:

```swift
import SwiftUI

/// The target's "Watch" tab: manage the watches linked to this goal and read
/// their merged activity feed. Applying an event's proposed action mutates the
/// target; "Discuss" pushes it into the target Assistant.
struct TargetWatchTabView: View {
    let viewModel: TargetWatchesViewModel
    /// Called with a seed prompt when the user taps Discuss on an event.
    var onDiscuss: (String) -> Void

    @Environment(AppState.self) private var appState
    @State private var showAddWatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            managementStrip
            Divider()
            feed
        }
        .padding()
        .sheet(isPresented: $showAddWatch) {
            CustomTrackManagementSheet(linkedTargetID: viewModel.target.id)
        }
    }

    private var managementStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Watches", systemImage: "binoculars").font(.headline)
                Spacer()
                Button { Task { await viewModel.scanAll() } } label: {
                    Label("Scan all", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(viewModel.watches.isEmpty)
                Button { showAddWatch = true } label: {
                    Label("Watch", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if viewModel.watches.isEmpty {
                Text("No watches yet — add a watch to track activity for this goal.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.watches) { watch in watchRow(watch) }
            }
            if let origin = viewModel.originTrack {
                Button { appState.navigateToTrack(origin.id) } label: {
                    Label("From track: \(origin.text)", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private func watchRow(_ watch: Track) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { watch.enabled },
                set: { viewModel.setCollecting(watch, $0) }
            )) { EmptyView() }
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .help(watch.enabled ? "Collecting" : "Paused")

            Text(watch.text).font(.subheadline).lineLimit(1)
            Spacer()
            if viewModel.isScanning(watch.id) {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Since last check") { Task { await viewModel.scanWatch(watch, since: nil, label: "since last check") } }
                Button("Last 7 days") { scan(watch, days: 7) }
                Button("Last 30 days") { scan(watch, days: 30) }
                Button("Last 90 days") { scan(watch, days: 90) }
                Button("All history") { Task { await viewModel.scanWatch(watch, since: nil, label: "all history") } }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(viewModel.isScanning(watch.id))

            Button(role: .destructive) { viewModel.deleteWatch(watch) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func scan(_ watch: Track, days: Int) {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        Task { await viewModel.scanWatch(watch, since: since, label: "last \(days) days") }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            if viewModel.events.isEmpty {
                Text("No activity yet. Scan a watch to backfill, or wait for the next daemon cycle.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    TargetWatchEventRow(event: event, viewModel: viewModel, onDiscuss: onDiscuss)
                        .onAppear { viewModel.markRead(event) }
                }
            }
        }
    }
}

/// One feed event: source watch + summary, confirmable target action, Discuss.
private struct TargetWatchEventRow: View {
    let event: TrackEvent
    let viewModel: TargetWatchesViewModel
    var onDiscuss: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if event.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.watchName(for: event.trackId).uppercased())
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(event.summary).font(.body)
                    if expanded, !event.detail.isEmpty {
                        Text(event.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .buttonStyle(.plain)
            }

            if event.actionStatus == "pending", let action = event.decodedAction {
                HStack(spacing: 8) {
                    Text(action.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Apply") { viewModel.applyAction(for: event) }.controlSize(.small)
                    Button("Dismiss") { viewModel.dismissAction(for: event) }
                        .controlSize(.small).buttonStyle(.borderless)
                }
            } else if event.actionStatus == "applied" {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button {
                    onDiscuss("Regarding this watch update: \"\(event.summary)\". How should this change the target?")
                } label: {
                    Label("Discuss", systemImage: "text.bubble").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Divider()
        }
        .padding(.vertical, 2)
    }
}
```

> Confirm `TrackEvent.trackId` (Swift camelCase for `track_id`) and `event.actionStatus` names against `Sources/Models/TrackEvent.swift` (they were defined there). `ProposedAction.reason` exists (used by the timeline row).

- [ ] **Step 2: Add the `.watch` tab + lifecycle to `TargetDetailView`**

Add the enum case (`TargetDetailView.swift:53-56`):

```swift
    enum Tab: String, CaseIterable {
        case details = "Details"
        case watch = "Watch"
        case links = "Links"
        case assistant = "Assistant"
    }
```

Add VM state near the other `@State` (around `:39`):

```swift
    @State private var watchesVM: TargetWatchesViewModel?
```

Add the switch arm (in the `switch selectedTab` block, `:110-115`):

```swift
                    case .watch:
                        if let vm = watchesVM {
                            TargetWatchTabView(viewModel: vm) { seed in
                                selectedTab = .assistant
                                chatVM?.inputText = seed
                            }
                        }
```

Build + start/stop the VM in the lifecycle. In `.onAppear` (where `chatVM` etc. are built, `:132`-ish) add:

```swift
                startWatchesVM(db: db)
```

In `.onChange(of: target.id)` add `watchesVM?.stop(); watchesVM = nil; startWatchesVM(db: db)` (mirror the existing pattern), and in `.onDisappear` add `watchesVM?.stop()`.

Add the builder method near the other `start*`/`load*` funcs:

```swift
    private func startWatchesVM(db: DatabaseManager) {
        guard let runner = ProcessCLIRunner.makeDefault() else { return }
        let vm = TargetWatchesViewModel(
            target: target,
            dbManager: db,
            scanService: TrackScanService(runner: runner),
            targetsViewModel: viewModel,
            scanCenter: appState.trackScanCenter
        )
        vm.start()
        watchesVM = vm
    }
```

> `viewModel` here is `TargetDetailView`'s `TargetsViewModel` (it already holds one — the detail is built from the list VM). Confirm the property name is `viewModel: TargetsViewModel`.

- [ ] **Step 3: Remove the Details `watchesSection`**

In `TargetDetailView.swift`: delete `watchesSection` from `detailsTab` (`:259`), delete the `watchesSection` computed property (`:271`), delete `loadLinkedWatches()` (`:314`) and its three call sites (in `.onAppear`, `.onChange(of: target.id)`, and `.onChange(of: showWatchSheet)`), and the `linkedWatches` state var. Keep the header **"Watch"** button + `showWatchSheet` sheet (quick create still lives in the header).

- [ ] **Step 4: Build**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -20`
Expected: Build complete. Fix any residual reference to the removed `linkedWatches`/`watchesSection`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift \
        WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift
git commit -m "feat(desktop): target Watch tab (feed + management), drop Details watches section"
```

---

## Task 4: Assistant watch-activity context

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift`
- Modify: `WatchtowerDesktop/Tests/` — add a focused test (new `TargetChatWatchContextTests.swift`, or extend an existing `TargetChatViewModelTests.swift` if present).

**Interfaces:**
- Consumes: `TrackEventQueries.fetchForTarget`, `Target`, `DatabasePool`.
- Produces: `TargetChatViewModel.watchActivityBlock(target:dbPool:) -> String` (nonisolated static), injected into `buildSystemPrompt`.

- [ ] **Step 1: Write the failing test** — `WatchtowerDesktop/Tests/TargetChatWatchContextTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TargetChatWatchContextTests: XCTestCase {
    static let trackEventsSQL = TargetWatchesViewModelTests.trackEventsSQL

    func testWatchActivityBlockPresentWhenEventsExistAbsentOtherwise() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try db.execute(sql: Self.trackEventsSQL) }

        let targetID = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID) })

        // No watches yet → empty block.
        let empty = TargetChatViewModel.watchActivityBlock(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(empty.isEmpty, "no watch events → no block")

        // Add a watch + an event → block appears with the summary.
        try manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                    origin, instruction, enabled, linked_target_id)
                VALUES ('U1', 'watch', '', 'task', 'watching', 'medium', 'custom', 'i', 1, ?)
                """, arguments: [targetID])
            let w = Int(db.lastInsertedRowID)
            try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 'refund approved')", arguments: [w])
        }
        let block = TargetChatViewModel.watchActivityBlock(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(block.contains("WATCH ACTIVITY"))
        XCTAssertTrue(block.contains("refund approved"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatWatchContextTests 2>&1 | tail -20`
Expected: FAIL — `watchActivityBlock` not defined.

- [ ] **Step 3: Add `watchActivityBlock` and inject it** in `TargetChatViewModel.swift`.

Add near `taskContextBlock` (`:472`):

```swift
    /// The `=== WATCH ACTIVITY ===` context block: recent events surfaced by the
    /// target's watches, so the assistant can act on them. Empty string when the
    /// target has no watch activity (the block is then omitted from the prompt).
    nonisolated static func watchActivityBlock(target: Target, dbPool: DatabasePool) -> String {
        let events = (try? dbPool.read { db in
            try TrackEventQueries.fetchForTarget(db, targetID: target.id, limit: 20)
        }) ?? []
        guard !events.isEmpty else { return "" }
        let lines = events.map { e -> String in
            let action = e.decodedAction.map { " [proposed: \($0.type.rawValue)]" } ?? ""
            return "- \(e.summary)\(action)"
        }.joined(separator: "\n")
        return """

        === WATCH ACTIVITY ===
        Recent updates surfaced by this target's watches (newest first). You may
        propose target mutations based on these via the task actions above.
        \(lines)
        """
    }
```

Inject into `buildSystemPrompt`'s return string, right after the `taskContextBlock` interpolation (`:519`-ish, where `\(Self.taskContextBlock(target))` appears):

```swift
        \(Self.taskContextBlock(target))
        \(Self.watchActivityBlock(target: target, dbPool: dbPool))
```

> `ProposedAction.type` is a `TargetActionKind` enum with `.rawValue` (used elsewhere). If `decodedAction`/`type` names differ, adapt.

- [ ] **Step 4: Run to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatWatchContextTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift \
        WatchtowerDesktop/Tests/TargetChatWatchContextTests.swift
git commit -m "feat(desktop): inject watch activity into target assistant context"
```

---

## Task 5: Full build + test gate

**Files:** none (verification).

- [ ] **Step 1: Build**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -10`
Expected: Build complete, no errors.

- [ ] **Step 2: Full test suite**

Run: `cd WatchtowerDesktop && swift test 2>&1 | tail -6`
Expected: all suites pass (≥ 92 prior tests + the new ones).

- [ ] **Step 3: Sanity-grep for leftovers**

Run: `grep -rn "watchesSection\|loadLinkedWatches\|linkedWatches" WatchtowerDesktop/Sources`
Expected: no matches (the Details watches section is fully removed).

- [ ] **Step 4: Commit any fixups**

```bash
git add -A
git commit -m "chore(desktop): green build/test for target Watch tab"
```

---

## Notes

- No Go/schema/migration changes — the feature is entirely Swift and reuses `track_events`, `linked_target_id`, `TargetActionExecutor`, `TrackScanCenter`, and the Swift-built target chat prompt.
- Property-name confirmations flagged inline (`Target.sourceType/sourceId`, `TrackEvent.trackId/actionStatus/decodedAction`, `TargetActionExecutor.apply` shape, `FakeCLIRunner` init label, `TargetDetailView.viewModel`) — each has an existing reference in the codebase to copy from; grep and adapt rather than guessing.
- The scan-range popover from `CustomTrackTimelineView` is intentionally simplified here to a per-watch Menu (fewer moving parts on the management strip); the full popover with a custom date picker remains on the track detail.
