# Target Extraction Survives Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Extract with AI" in the New Target sheet keeps running and reports its result (via a native macOS notification) even if the user closes the sheet or navigates away, instead of blocking the UI and silently losing the result.

**Architecture:** A new `@MainActor @Observable` `TargetExtractCenter`, held on `AppState` (same shape as the existing `TrackScanCenter`), becomes the single source of truth for in-flight/pending extraction state. `CreateTargetSheet` delegates to it instead of using view-local `@State`, and `TargetsListView` (the Targets tab) acts as the catch-all consumer for results that land after the initiating sheet is gone, reachable via a native notification tap.

**Tech Stack:** Swift 5.10, SwiftUI, `@Observable` (Observation framework), XCTest, existing `CLIRunnerProtocol` / `TargetExtractService` / `NotificationService`.

## Global Constraints

- No new toast/banner UI component — completion is surfaced only via a native macOS notification (`NotificationService`), per the approved design spec `docs/superpowers/specs/2026-07-09-target-extract-background-design.md`.
- Dismissing/cancelling the New Target sheet never aborts the extraction.
- Single in-flight slot app-wide: starting a second extraction while one is running is blocked (button disabled), never queued.
- Views (`CreateTargetSheet`, `TargetsListView`) stay untested per house style — only the new `TargetExtractCenter` gets unit tests.

---

### Task 1: `NotificationService` completion notifications

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/NotificationService.swift:123-136` (append after `sendDailySummaryNotification`, before the closing `}` of the class)

**Interfaces:**
- Produces: `NotificationService.sendTargetExtractReadyNotification(count: Int)`, `NotificationService.sendTargetExtractFailedNotification(reason: String)` — consumed by Task 2's `TargetExtractCenter.start()`. Both set `userInfo["type"] = "target_extract"`, consumed by Task 4.

- [ ] **Step 1: Add the two notification methods**

In `WatchtowerDesktop/Sources/Services/NotificationService.swift`, find the end of `sendDailySummaryNotification`:

```swift
    func sendDailySummaryNotification(summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "Daily summary ready"
        content.body = String(summary.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "daily_summary"]

        let request = UNNotificationRequest(
            identifier: "daily-summary-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

Replace the closing `}` after it with two new methods followed by the closing brace:

```swift
    func sendDailySummaryNotification(summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "Daily summary ready"
        content.body = String(summary.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "daily_summary"]

        let request = UNNotificationRequest(
            identifier: "daily-summary-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTargetExtractReadyNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Target draft ready"
        content.body = count == 1
            ? "1 target extracted — tap to review"
            : "\(count) targets extracted — tap to review"
        content.sound = .default
        content.userInfo = ["type": "target_extract"]

        let request = UNNotificationRequest(
            identifier: "target-extract-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTargetExtractFailedNotification(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Target extraction failed"
        content.body = String(reason.prefix(200))
        content.sound = .default
        content.userInfo = ["type": "target_extract"]

        let request = UNNotificationRequest(
            identifier: "target-extract-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/NotificationService.swift
git commit -m "$(cat <<'EOF'
feat(desktop): add target-extraction completion notifications

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `TargetExtractCenter`

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift`
- Test: `WatchtowerDesktop/Tests/TargetExtractCenterTests.swift`

**Interfaces:**
- Consumes: `CLIRunnerProtocol` (`WatchtowerDesktop/Sources/Services/CLIRunner.swift`), `TargetExtractService` / `TargetExtractResult` (`WatchtowerDesktop/Sources/Services/TargetExtractService.swift`), `NotificationService.sendTargetExtractReadyNotification(count:)` / `.sendTargetExtractFailedNotification(reason:)` (Task 1), `FakeCLIRunner` / `CLIRunnerError` (test-only, `WatchtowerDesktop/Tests/Helpers/FakeCLIRunner.swift`).
- Produces: `final class TargetExtractCenter` with `var isRunning: Bool`, `var draftText: String`, `var pendingResult: TargetExtractResult?`, `var pendingError: String?`, `func start(text: String, sourceRef: String = "", runner: CLIRunnerProtocol) async`, `func clearPending()` — consumed by Task 3 (AppState), Task 5 (CreateTargetSheet), Task 6 (TargetsListView).

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/TargetExtractCenterTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

@MainActor
final class TargetExtractCenterTests: XCTestCase {

    func testStartOnSuccessSetsPendingResultAndClearsRunning() async {
        let center = TargetExtractCenter()
        let json = """
        {
          "extracted": [
            {
              "text": "Ship feature",
              "intent": "",
              "level": "day",
              "custom_label": "",
              "period_start": "2026-07-09",
              "period_end": "2026-07-09",
              "priority": "medium",
              "due_date": "",
              "parent_id": null,
              "ai_level_confidence": null,
              "secondary_links": []
            }
          ],
          "omitted_count": 0,
          "notes": ""
        }
        """
        let runner = FakeCLIRunner(stdout: Data(json.utf8))

        await center.start(text: "ship feature", runner: runner)

        XCTAssertFalse(center.isRunning)
        XCTAssertEqual(center.pendingResult?.extracted.count, 1)
        XCTAssertEqual(center.pendingResult?.extracted.first?.text, "Ship feature")
        XCTAssertNil(center.pendingError)
    }

    func testStartWithEmptyExtractionSetsPendingError() async {
        let center = TargetExtractCenter()
        let runner = FakeCLIRunner(stdout: Data("{\"extracted\": [], \"omitted_count\": 0, \"notes\": \"\"}".utf8))

        await center.start(text: "nothing here", runner: runner)

        XCTAssertFalse(center.isRunning)
        XCTAssertNil(center.pendingResult)
        XCTAssertEqual(center.pendingError, "AI returned no extracted targets")
    }

    func testStartOnCLIErrorSetsPendingError() async {
        let center = TargetExtractCenter()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))

        await center.start(text: "sample", runner: runner)

        XCTAssertFalse(center.isRunning)
        XCTAssertNil(center.pendingResult)
        XCTAssertTrue(center.pendingError?.hasPrefix("Extract failed:") ?? false)
    }

    func testStartWhileRunningIsANoOp() async {
        let center = TargetExtractCenter()
        center.isRunning = true
        center.draftText = "original draft"

        let runner = FakeCLIRunner(stdout: Data("{\"extracted\": [], \"omitted_count\": 0, \"notes\": \"\"}".utf8))
        await center.start(text: "second draft", runner: runner)

        XCTAssertTrue(center.isRunning, "the guard must leave the in-flight flag untouched")
        XCTAssertEqual(center.draftText, "original draft", "a blocked start must not overwrite the in-flight draft")
        XCTAssertEqual(runner.invocations.count, 0, "the CLI runner must never be invoked while blocked")
    }

    func testClearPendingClearsBothResultAndError() {
        let center = TargetExtractCenter()
        center.pendingResult = TargetExtractResult(extracted: [], omittedCount: 0, notes: "")
        center.pendingError = "some error"

        center.clearPending()

        XCTAssertNil(center.pendingResult)
        XCTAssertNil(center.pendingError)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter TargetExtractCenterTests`
Expected: FAIL to build with `cannot find type 'TargetExtractCenter' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Implement `TargetExtractCenter`**

Create `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift`:

```swift
import Foundation

/// App-wide, single-slot registry for the "Extract with AI" target-extraction
/// call. The extraction subprocess call can take up to the CLI's extract
/// timeout; routing it through this AppState-held center (instead of
/// view-local `@State` on `CreateTargetSheet`) means the result is never lost
/// if the presenting sheet is closed before the call finishes — `start()`'s
/// `Task` is rooted here, not in the view.
@MainActor
@Observable
final class TargetExtractCenter {
    /// True while a `start()` call is in flight. Only one extraction can run
    /// at a time app-wide; a second `start()` call while this is true is a
    /// no-op (single-slot guard).
    var isRunning = false
    /// The text of the in-flight (or most recently started) extraction, so a
    /// caller can tell whether a running extraction is its own or someone
    /// else's.
    var draftText = ""
    /// Set on successful, non-empty extraction. Cleared by `clearPending()`
    /// once a consumer has presented it.
    var pendingResult: TargetExtractResult?
    /// Set on CLI failure or an empty extraction result. Cleared by
    /// `clearPending()` once a consumer has surfaced it.
    var pendingError: String?

    private let notificationService: NotificationService

    init(notificationService: NotificationService = .shared) {
        self.notificationService = notificationService
    }

    /// Runs the extraction. Guards against overlapping calls (single-slot);
    /// a call made while one is already running returns immediately without
    /// touching `draftText`/`pendingResult`/`pendingError`.
    func start(text: String, sourceRef: String = "", runner: CLIRunnerProtocol) async {
        guard !isRunning else { return }
        isRunning = true
        draftText = text
        pendingResult = nil
        pendingError = nil

        do {
            let result = try await TargetExtractService(runner: runner)
                .extract(text: text, sourceRef: sourceRef)
            if result.extracted.isEmpty {
                pendingError = "AI returned no extracted targets"
                notificationService.sendTargetExtractFailedNotification(reason: pendingError!)
            } else {
                pendingResult = result
                notificationService.sendTargetExtractReadyNotification(count: result.extracted.count)
            }
        } catch {
            pendingError = "Extract failed: \(error.localizedDescription)"
            notificationService.sendTargetExtractFailedNotification(reason: pendingError!)
        }

        isRunning = false
    }

    /// Clears any pending result/error once a consumer has presented it.
    func clearPending() {
        pendingResult = nil
        pendingError = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter TargetExtractCenterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift WatchtowerDesktop/Tests/TargetExtractCenterTests.swift
git commit -m "$(cat <<'EOF'
feat(desktop): add TargetExtractCenter for background target extraction

Single-slot, AppState-ownable registry for the "Extract with AI" call so
its state survives the New Target sheet being closed mid-extraction.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire `TargetExtractCenter` into `AppState`

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift:28`

**Interfaces:**
- Consumes: `TargetExtractCenter` (Task 2).
- Produces: `appState.targetExtractCenter` — consumed by Task 5 (`CreateTargetSheet`) and Task 6 (`TargetsListView`).

- [ ] **Step 1: Add the property next to `trackScanCenter`**

In `WatchtowerDesktop/Sources/App/AppState.swift`, find:

```swift
    /// App-wide registry of in-flight custom-track scans, so the "scanning"
    /// indicator survives navigating away from a track's detail.
    let trackScanCenter = TrackScanCenter()
```

Add immediately after it:

```swift

    /// App-wide, single-slot registry for the "Extract with AI" target
    /// extraction call, so its state survives the New Target sheet being
    /// closed mid-extraction.
    let targetExtractCenter = TargetExtractCenter()
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/App/AppState.swift
git commit -m "$(cat <<'EOF'
feat(desktop): hold TargetExtractCenter on AppState

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Notification-click navigation

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift:41-44`

**Interfaces:**
- Consumes: `userInfo["type"] == "target_extract"` (Task 1).
- Produces: clicking the notification sets `appState.selectedDestination = .targets`, which Task 6's `TargetsListView.onAppear`/`onChange` picks up.

- [ ] **Step 1: Add the new case to `NotificationDelegate`**

In `WatchtowerDesktop/Sources/App/WatchtowerApp.swift`, find:

```swift
            case "track", "track_update":
                appState?.selectedDestination = .tracks
            case "task_overdue":
                appState?.selectedDestination = .targets
            case "daily_summary":
                appState?.selectedDestination = .digests
```

Replace with:

```swift
            case "track", "track_update":
                appState?.selectedDestination = .tracks
            case "task_overdue", "target_extract":
                appState?.selectedDestination = .targets
            case "daily_summary":
                appState?.selectedDestination = .digests
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/App/WatchtowerApp.swift
git commit -m "$(cat <<'EOF'
feat(desktop): route target-extraction notification taps to Targets tab

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `CreateTargetSheet` delegates to the center

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift`

**Interfaces:**
- Consumes: `appState.targetExtractCenter` (Task 2 + 3): `isRunning: Bool`, `draftText: String`, `pendingResult: TargetExtractResult?`, `pendingError: String?`, `start(text:runner:) async`, `clearPending()`.
- Produces: no change to `CreateTargetSheet`'s own public init/params — this task only changes its internals.

- [ ] **Step 1: Replace the extraction `@State` and add `awaitingOwnExtraction`**

In `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift`, find:

```swift
    @State private var errorMessage: String?
    @State private var showExtractSheet = false
    @State private var extractedResult: TargetExtractResult?
    @State private var isExtracting = false
```

Replace with:

```swift
    @State private var errorMessage: String?
    @State private var showExtractSheet = false
    @State private var extractedResult: TargetExtractResult?
    /// True only while THIS sheet instance is the one that started the
    /// in-flight extraction — gates the `isRunning` transition handler below
    /// so a sheet never reacts to a result/error started by a different
    /// CreateTargetSheet instance elsewhere in the app.
    @State private var awaitingOwnExtraction = false
```

- [ ] **Step 2: Add the completion handler next to the existing `.sheet` modifier**

Find:

```swift
        .sheet(isPresented: $showExtractSheet) {
            if let result = extractedResult {
                ExtractPreviewSheet(
                    proposed: result.extracted,
                    omittedCount: result.omittedCount,
                    notes: result.notes,
                    onCreateSelected: { _ in
                        dismiss()
                    }
                )
            }
        }
    }
```

Replace with:

```swift
        .sheet(isPresented: $showExtractSheet) {
            if let result = extractedResult {
                ExtractPreviewSheet(
                    proposed: result.extracted,
                    omittedCount: result.omittedCount,
                    notes: result.notes,
                    onCreateSelected: { _ in
                        dismiss()
                    }
                )
            }
        }
        .onChange(of: appState.targetExtractCenter.isRunning) { _, running in
            guard awaitingOwnExtraction, !running else { return }
            awaitingOwnExtraction = false
            if let result = appState.targetExtractCenter.pendingResult {
                extractedResult = result
                showExtractSheet = true
                appState.targetExtractCenter.clearPending()
            } else if let error = appState.targetExtractCenter.pendingError {
                errorMessage = error
                appState.targetExtractCenter.clearPending()
            }
        }
    }
```

- [ ] **Step 3: Update `extractButton` to read from the center**

Find:

```swift
    private var extractButton: some View {
        HStack {
            Button {
                Task { await runExtract() }
            } label: {
                if isExtracting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Extracting…")
                    }
                } else {
                    Label("Extract with AI", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isExtracting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Run the entered text through the LLM to propose structured targets")
            Spacer()
        }
    }
```

Replace with:

```swift
    private var extractButton: some View {
        let center = appState.targetExtractCenter
        return HStack {
            Button {
                Task { await runExtract() }
            } label: {
                if center.isRunning && awaitingOwnExtraction {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Extracting…")
                    }
                } else {
                    Label("Extract with AI", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .disabled(center.isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(
                center.isRunning && !awaitingOwnExtraction
                    ? "An extraction is already running — wait for it to finish"
                    : "Run the entered text through the LLM to propose structured targets"
            )
            Spacer()
        }
    }
```

- [ ] **Step 4: Rewrite `runExtract()` to delegate to the center**

Find:

```swift
    private func runExtract() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        isExtracting = true
        errorMessage = nil
        defer { isExtracting = false }
        do {
            let service = TargetExtractService(runner: runner)
            let result = try await service.extract(text: text)
            if result.extracted.isEmpty {
                errorMessage = "AI returned no extracted targets"
                return
            }
            extractedResult = result
            showExtractSheet = true
        } catch {
            errorMessage = "Extract failed: \(error.localizedDescription)"
        }
    }
```

Replace with:

```swift
    private func runExtract() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        errorMessage = nil
        awaitingOwnExtraction = true
        await appState.targetExtractCenter.start(text: text, runner: runner)
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build`
Expected: Build succeeds with no errors. (`isExtracting` no longer exists anywhere in the file — a leftover reference would be a compile error.)

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift
git commit -m "$(cat <<'EOF'
fix(desktop): New Target extraction survives closing the sheet

"Extract with AI" now delegates to the AppState-held TargetExtractCenter
instead of view-local @State, so closing/cancelling the sheet no longer
loses an in-flight extraction's result.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `TargetsListView` catch-all for results left unseen

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetsListView.swift`

**Interfaces:**
- Consumes: `appState.targetExtractCenter` (Task 2 + 3), `TargetsViewModel.load()` (existing), `ExtractPreviewSheet` (existing, `WatchtowerDesktop/Sources/Views/Targets/ExtractPreviewSheet.swift`).
- Produces: no new public interface — this is the terminal consumer.

- [ ] **Step 1: Add state for the standalone preview/error**

Find:

```swift
struct TargetsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: TargetsViewModel?
    @State private var selectedItemID: Int?
    @State private var showCreateSheet = false
    @State private var searchText = ""
    @State private var pendingDeleteTarget: Target?
```

Replace with:

```swift
struct TargetsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: TargetsViewModel?
    @State private var selectedItemID: Int?
    @State private var showCreateSheet = false
    @State private var searchText = ""
    @State private var pendingDeleteTarget: Target?
    /// Catch-all for an extraction that finished after its originating
    /// CreateTargetSheet was closed (e.g. the user came back via the
    /// completion notification).
    @State private var showExtractPreview = false
    @State private var extractPreviewResult: TargetExtractResult?
    @State private var extractErrorMessage: String?
```

- [ ] **Step 2: Consume pending state on appear and on change**

Find:

```swift
        .onAppear {
            initViewModel()
            if let id = appState.pendingTargetID {
                selectedItemID = id
                appState.pendingTargetID = nil
            }
        }
        .onChange(of: appState.isDBAvailable) { initViewModel() }
        .onChange(of: appState.pendingTargetID) { _, newID in
            if let id = newID {
                selectedItemID = id
                appState.pendingTargetID = nil
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateTargetSheet()
        }
```

Replace with:

```swift
        .onAppear {
            initViewModel()
            if let id = appState.pendingTargetID {
                selectedItemID = id
                appState.pendingTargetID = nil
            }
            consumePendingExtraction()
        }
        .onChange(of: appState.isDBAvailable) { initViewModel() }
        .onChange(of: appState.pendingTargetID) { _, newID in
            if let id = newID {
                selectedItemID = id
                appState.pendingTargetID = nil
            }
        }
        .onChange(of: appState.targetExtractCenter.isRunning) { _, _ in
            consumePendingExtraction()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateTargetSheet()
        }
        .sheet(isPresented: $showExtractPreview) {
            if let result = extractPreviewResult {
                ExtractPreviewSheet(
                    proposed: result.extracted,
                    omittedCount: result.omittedCount,
                    notes: result.notes,
                    onCreateSelected: { _ in
                        viewModel?.load()
                    }
                )
            }
        }
        .alert(
            "Extraction failed",
            isPresented: Binding(
                get: { extractErrorMessage != nil },
                set: { if !$0 { extractErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(extractErrorMessage ?? "")
        }
```

- [ ] **Step 3: Add the `consumePendingExtraction()` helper**

Find:

```swift
    private func initViewModel() {
        guard viewModel == nil, let db = appState.databaseManager else { return }
        let vm = TargetsViewModel(dbManager: db)
        viewModel = vm
        vm.startObserving()
    }
```

Replace with:

```swift
    private func initViewModel() {
        guard viewModel == nil, let db = appState.databaseManager else { return }
        let vm = TargetsViewModel(dbManager: db)
        viewModel = vm
        vm.startObserving()
    }

    /// Picks up a result/error left behind by a CreateTargetSheet that has
    /// since been closed (e.g. the user tapped the completion notification).
    /// A no-op while an extraction is still running or nothing is pending.
    private func consumePendingExtraction() {
        let center = appState.targetExtractCenter
        guard !center.isRunning else { return }
        if let result = center.pendingResult {
            extractPreviewResult = result
            showExtractPreview = true
            center.clearPending()
        } else if let error = center.pendingError {
            extractErrorMessage = error
            center.clearPending()
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/TargetsListView.swift
git commit -m "$(cat <<'EOF'
feat(desktop): Targets tab picks up extractions finished after the sheet closed

Catches a pending TargetExtractCenter result/error on appear and on the
running-state transition, so the completion notification's tap has
something to land on.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full Swift test suite**

Run: `cd WatchtowerDesktop && swift build && swift test 2>&1 | tail -40`
Expected: `** TEST SUCCEEDED **` (or the equivalent all-pass summary), including the 5 new `TargetExtractCenterTests`.

- [ ] **Step 2: Run the Swift linter**

Run: `make lint-swift`
Expected: No new warnings/errors attributable to the files touched in Tasks 1–6.

- [ ] **Step 3: Manual verification (per the `verify` skill) — the exact reported scenario**

With the Watchtower daemon/CLI installed and a workspace configured:
1. Launch the Desktop app (`make app-dev` or the existing dev-run flow).
2. Open "New Target" (any call site, e.g. the Targets tab's `+` button).
3. Paste a non-trivial block of text (several action items, similar to the original bug report) and click "Extract with AI".
4. Immediately click "Cancel" to close the sheet while extraction is still running.
5. Confirm the app remains fully usable (no blocking modal) while extraction continues.
6. Wait for the system notification "Target draft ready" to appear (up to the configured `targets.extract.timeout_seconds`, currently 90s).
7. Click the notification: confirm the app activates, switches to the Targets tab, and the `ExtractPreviewSheet` opens showing the extracted draft(s).
8. Repeat steps 2–4, but this time leave the sheet open until completion: confirm the preview opens automatically in the still-open sheet, without needing the notification.
9. While one extraction is running, open a second "New Target" sheet elsewhere and confirm its "Extract with AI" button is disabled with the "already running" tooltip.

- [ ] **Step 4: Fix any issues found during manual verification, then re-run Steps 1–2**

If manual verification surfaces a bug, fix it, re-run the affected task's build/test step, and commit the fix separately (do not amend earlier task commits).
