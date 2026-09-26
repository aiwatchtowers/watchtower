# Target "Extract with AI" Background Operation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn target "Extract with AI" into a navigation-surviving background operation with no timeout, a floating status/result capsule, and human-readable errors instead of raw Go error chains.

**Architecture:** `TargetExtractCenter` (already on `AppState`) becomes an active, phase-driven `@Observable` that owns its own cancellable `Task` (mirroring `MeetingRecorderCenter`). A new global `ExtractIndicatorView` capsule — mounted next to `RecordingIndicatorView` in `WatchtowerApp` — reflects the phase from every screen and presents the result review sheet app-level. The Go pipeline drops its extraction deadline (config `<= 0` = no timeout); the only early stop is the user's Cancel, which terminates the CLI subprocess.

**Tech Stack:** Go 1.25 (`internal/targets`, `internal/config`), SwiftUI + `@Observable` (`WatchtowerDesktop`), GRDB (unchanged), XCTest / Go `testing`.

## Global Constraints

- Swift language mode 5.10, macOS 14+ (Xcode 16+ toolchain). `@Observable @MainActor` centers, MVVM shape.
- Go: `gofmt` + `go vet` clean; mirror config default changes only where they live (no `schema.sql` impact — no DB change here).
- The `watchtower targets extract --json` JSON contract is unchanged: `{extracted:[…], omitted_count:int, notes:string}`.
- No new DB migration, no `docs/inventory/` contract touched (there is no inventory entry for target extraction).
- All GitHub-facing text / commit messages in English.
- Do not weaken any existing guard test.

---

## File Structure

- `internal/targets/pipeline.go` — MODIFY: `<= 0` timeout means no deadline.
- `internal/config/defaults.go` — MODIFY: `DefaultTargetsExtractTimeoutSeconds` 90 → 0.
- `internal/targets/pipeline_test.go` — MODIFY: add no-timeout / control tests.
- `WatchtowerDesktop/Sources/Services/CLIRunner.swift` — MODIFY: `ProcessCLIRunner.run` terminates the subprocess on Task cancellation.
- `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift` — REWRITE: phase model, own Task, cancel/retry/dismiss, friendly-error mapping.
- `WatchtowerDesktop/Tests/TargetExtractCenterTests.swift` — REWRITE to the phase API + navigation-surviving / empty / cancel tests.
- `WatchtowerDesktop/Tests/Helpers/FakeCLIRunner.swift` — MODIFY: add a block-until-cancelled mode for the cancel test.
- `WatchtowerDesktop/Sources/Views/Targets/ExtractIndicatorView.swift` — CREATE: floating capsule + app-level preview sheet.
- `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` — MODIFY: mount `ExtractIndicatorView`.
- `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift` — MODIFY: fire-and-forget start; auto-open preview only while the sheet is still up.
- `WatchtowerDesktop/Sources/Views/Targets/TargetsListView.swift` — MODIFY: remove the now-redundant extraction catch-all + raw error alert (the capsule owns global surfacing).

---

## Task 1: Go — extraction runs with no timeout

**Files:**
- Modify: `internal/targets/pipeline.go:52-58`
- Modify: `internal/config/defaults.go:69`
- Test: `internal/targets/pipeline_test.go`

**Interfaces:**
- Consumes: `config.TargetsConfig{ Extract: config.TargetsExtractConfig{ Enabled bool; TimeoutSeconds int } }`, `digest.Generator.Generate(ctx, system, user, _) (string, *digest.Usage, string, error)`.
- Produces: unchanged `Pipeline.Extract(ctx, ExtractRequest) (*ExtractResult, error)` signature; behavior change only.

- [ ] **Step 1: Write the failing test**

Add to `internal/targets/pipeline_test.go`. This generator captures whether the context handed to the AI call carries a deadline:

```go
// ctxDeadlineGenerator records whether the context passed to Generate had a
// deadline, so the timeout-wiring can be asserted without wall-clock waits.
type ctxDeadlineGenerator struct {
	response     string
	sawDeadline  bool
}

func (g *ctxDeadlineGenerator) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	_, g.sawDeadline = ctx.Deadline()
	return g.response, &digest.Usage{InputTokens: 1, OutputTokens: 1}, "", nil
}

func TestPipeline_Extract_NonPositiveTimeoutHasNoDeadline(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	gen := &ctxDeadlineGenerator{response: `{"extracted":[],"omitted_count":0,"notes":""}`}
	cfg := &config.TargetsConfig{Extract: config.TargetsExtractConfig{Enabled: true, TimeoutSeconds: 0}}
	p := New(d, cfg, gen, nil, "", nil)

	if _, err := p.Extract(context.Background(), ExtractRequest{RawText: "anything", EntryPoint: "cli"}); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if gen.sawDeadline {
		t.Fatalf("expected no deadline on the AI context when TimeoutSeconds <= 0")
	}
}

func TestPipeline_Extract_PositiveTimeoutStillHasDeadline(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer d.Close()

	gen := &ctxDeadlineGenerator{response: `{"extracted":[],"omitted_count":0,"notes":""}`}
	cfg := &config.TargetsConfig{Extract: config.TargetsExtractConfig{Enabled: true, TimeoutSeconds: 30}}
	p := New(d, cfg, gen, nil, "", nil)

	if _, err := p.Extract(context.Background(), ExtractRequest{RawText: "anything", EntryPoint: "cli"}); err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if !gen.sawDeadline {
		t.Fatalf("expected a deadline on the AI context when TimeoutSeconds > 0")
	}
}
```

Ensure `"watchtower/internal/config"` is in the test file's imports (add it if the import block lacks it).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/targets/ -run 'TestPipeline_Extract_(NonPositive|Positive)Timeout' -v`
Expected: `TestPipeline_Extract_NonPositiveTimeoutHasNoDeadline` FAILS ("expected no deadline") because today a non-positive config value falls back to the 90 s default and always sets a deadline. The positive-timeout test passes.

- [ ] **Step 3: Change the timeout wiring in `pipeline.go`**

Replace lines 52-58 (the `// Apply timeout from config.` block through the `aiCtx, cancel := context.WithTimeout(...)` line) with:

```go
	// Apply timeout from config. A non-positive value disables the deadline
	// entirely: extraction is a user-cancellable background op (Desktop
	// capsule), not a wall-clock-bounded call — see the 2026-07-16 spec.
	// cfg == nil keeps the built-in default (also 0 → no deadline).
	timeoutSec := config.DefaultTargetsExtractTimeoutSeconds
	if p.cfg != nil {
		timeoutSec = p.cfg.Extract.TimeoutSeconds
	}
	var aiCtx context.Context
	var cancel context.CancelFunc
	if timeoutSec > 0 {
		aiCtx, cancel = context.WithTimeout(ctx, time.Duration(timeoutSec)*time.Second)
	} else {
		aiCtx, cancel = context.WithCancel(ctx)
	}
	defer cancel()
```

- [ ] **Step 4: Change the default in `defaults.go`**

At `internal/config/defaults.go:69`, change:

```go
	DefaultTargetsExtractTimeoutSeconds = 90
```
to:
```go
	DefaultTargetsExtractTimeoutSeconds = 0 // 0 = no deadline; extraction is user-cancellable in the Desktop capsule
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/targets/ ./internal/config/ 2>&1 | tail -20`
Expected: PASS (both new tests + existing pipeline/config tests). `time` is still used (the positive branch), so no unused-import error.

- [ ] **Step 6: Vet + commit**

```bash
go vet ./internal/targets/ ./internal/config/
git add internal/targets/pipeline.go internal/config/defaults.go internal/targets/pipeline_test.go
git commit -m "feat(targets): extraction runs with no timeout when config <= 0"
```

---

## Task 2: Swift — ProcessCLIRunner terminates its subprocess on cancellation

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/CLIRunner.swift:48-79`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ProcessCLIRunner.run(args:)` unchanged signature; now honors Swift Task cancellation by terminating the process and throwing `CancellationError`.

This is production glue for the capsule's Cancel. It is exercised end-to-end by `/verify` (real subprocess); the cancel *state machine* is unit-tested at the Center layer in Task 3 with a fake runner. No unit test here.

- [ ] **Step 1: Wrap the blocking read/wait in a cancellation handler**

In `ProcessCLIRunner.run(args:)`, replace the block from `// Read pipe data BEFORE waitUntilExit...` (line 66) through `return stdoutData` (line 78) with:

```swift
        // Terminate the subprocess if the awaiting Task is cancelled (the user
        // pressed Cancel in the extraction capsule). `readDataToEndOfFile` /
        // `waitUntilExit` run on the calling cooperative-pool thread (this
        // method is a nonisolated async call, so it never blocks the main
        // actor); terminate() from the cancel handler unblocks the wait.
        return try await withTaskCancellationHandler {
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if Task.isCancelled {
                throw CancellationError()
            }
            let exitCode = process.terminationStatus
            if exitCode != 0 {
                let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw CLIRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }
            return stdoutData
        } onCancel: {
            process.terminate()
        }
```

Note: under Swift 5.10 mode `process` captured by the `@Sendable` `onCancel` closure may emit a Sendable warning — acceptable (the harness is single-writer here; terminate is thread-safe). Do not add `@unchecked Sendable` wrappers.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build 2>build.log; echo "exit=$?"; tail -20 build.log`
Expected: `exit=0` (warnings allowed; no errors).

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/CLIRunner.swift
git commit -m "feat(desktop): ProcessCLIRunner terminates subprocess on cancellation"
```

---

## Task 3: Swift — TargetExtractCenter phase model, own Task, cancel/retry, friendly errors

**Files:**
- Rewrite: `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/FakeCLIRunner.swift`
- Rewrite: `WatchtowerDesktop/Tests/TargetExtractCenterTests.swift`

**Interfaces:**
- Consumes: `TargetExtractService(runner:).extract(text:sourceRef:) async throws -> TargetExtractResult`; `CLIRunnerProtocol`; `TargetExtractNotifying`.
- Produces (relied on by Tasks 4 & 5):
  - `enum TargetExtractCenter.Phase: Equatable { case idle, extracting, ready(count: Int), empty, failed(message: String, canRetry: Bool) }`
  - `private(set) var phase: Phase`
  - `private(set) var result: TargetExtractResult?` (set with `.ready`)
  - `private(set) var lastRawError: String?` (raw stderr for the "Show details" disclosure)
  - `func start(text: String, sourceRef: String = "", runner: CLIRunnerProtocol)` — non-async, fire-and-forget
  - `func cancel()`, `func retry()`, `func dismiss()`
  - `var task: Task<Void, Never>?` — internal, so tests can `await center.task?.value`

- [ ] **Step 1: Add a block-until-cancelled mode to FakeCLIRunner**

In `WatchtowerDesktop/Tests/Helpers/FakeCLIRunner.swift`, replace the body with:

```swift
import Foundation
@testable import WatchtowerDesktop

/// Shared test double for `CLIRunnerProtocol`. Accumulates every invocation
/// so assertions can cover sequences of calls, not just the latest.
final class FakeCLIRunner: CLIRunnerProtocol {
    private let stdoutData: Data
    var shouldThrow: Error?
    /// When true, `run` suspends until the awaiting Task is cancelled, then
    /// throws `CancellationError` — models a long extraction the user cancels.
    var blockUntilCancelled = false
    private(set) var invocations: [[String]] = []

    init(stdout: Data = Data(), error: Error? = nil) {
        self.stdoutData = stdout
        self.shouldThrow = error
    }

    func run(args: [String]) async throws -> Data {
        invocations.append(args)
        if blockUntilCancelled {
            // Sleeps effectively forever; cancellation throws CancellationError.
            try await Task.sleep(nanoseconds: .max)
        }
        if let shouldThrow { throw shouldThrow }
        return stdoutData
    }
}
```

- [ ] **Step 2: Write the failing tests**

Replace `WatchtowerDesktop/Tests/TargetExtractCenterTests.swift` with:

```swift
import XCTest
@testable import WatchtowerDesktop

final class FakeTargetExtractNotifier: TargetExtractNotifying {
    private(set) var readyCalls: [Int] = []
    private(set) var failedCalls: [String] = []
    func sendTargetExtractReadyNotification(count: Int) { readyCalls.append(count) }
    func sendTargetExtractFailedNotification(reason: String) { failedCalls.append(reason) }
}

@MainActor
final class TargetExtractCenterTests: XCTestCase {

    private func oneTargetJSON() -> Data {
        Data("""
        {"extracted":[{"text":"Ship feature","intent":"","level":"day","custom_label":"",
        "period_start":"2026-07-09","period_end":"2026-07-09","priority":"medium",
        "parent_id":null,"ai_level_confidence":null,"secondary_links":[]}],
        "omitted_count":0,"notes":""}
        """.utf8)
    }

    func testSuccessGoesToReadyWithResult() async {
        let notifier = FakeTargetExtractNotifier()
        let center = TargetExtractCenter(notificationService: notifier)
        center.start(text: "ship feature", runner: FakeCLIRunner(stdout: oneTargetJSON()))
        await center.task?.value

        XCTAssertEqual(center.phase, .ready(count: 1))
        XCTAssertEqual(center.result?.extracted.count, 1)
        XCTAssertEqual(notifier.readyCalls, [1])
    }

    func testEmptyExtractionGoesToEmptyNotFailed() async {
        let notifier = FakeTargetExtractNotifier()
        let center = TargetExtractCenter(notificationService: notifier)
        let runner = FakeCLIRunner(stdout: Data(#"{"extracted":[],"omitted_count":0,"notes":""}"#.utf8))
        center.start(text: "nothing here", runner: runner)
        await center.task?.value

        XCTAssertEqual(center.phase, .empty)
        XCTAssertNil(center.result)
    }

    func testCLIErrorMapsToFriendlyFailed() async {
        let notifier = FakeTargetExtractNotifier()
        let center = TargetExtractCenter(notificationService: notifier)
        let stderr = "extraction failed: AI extraction call: claude CLI error: context deadline exceeded"
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
        center.start(text: "sample", runner: runner)
        await center.task?.value

        XCTAssertEqual(center.phase, .failed(message: "Extraction took too long. Try again.", canRetry: true))
        XCTAssertEqual(center.lastRawError?.contains("deadline exceeded"), true)
        XCTAssertEqual(notifier.failedCalls.count, 1)
    }

    func testResultSurvivesAfterStartReturns() async {
        // "начал → ушёл → вернулся": nothing holds the result but the Center.
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        center.start(text: "ship feature", runner: FakeCLIRunner(stdout: oneTargetJSON()))
        await center.task?.value
        // Simulate a consumer coming back later and reading the Center.
        XCTAssertEqual(center.phase, .ready(count: 1))
        XCTAssertEqual(center.result?.extracted.first?.text, "Ship feature")
    }

    func testCancelMidRunReturnsToIdle() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let runner = FakeCLIRunner()
        runner.blockUntilCancelled = true
        center.start(text: "long one", runner: runner)
        XCTAssertEqual(center.phase, .extracting)

        center.cancel()
        await center.task?.value

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.result)
    }

    func testStartWhileExtractingIsANoOp() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let blocking = FakeCLIRunner()
        blocking.blockUntilCancelled = true
        center.start(text: "first", runner: blocking)
        XCTAssertEqual(center.phase, .extracting)

        let second = FakeCLIRunner(stdout: oneTargetJSON())
        center.start(text: "second", runner: second)
        XCTAssertEqual(second.invocations.count, 0, "a blocked start must not invoke the runner")

        center.cancel()
        await center.task?.value
    }

    func testRetryReRunsWithRememberedText() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let failing = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "network unreachable"))
        center.start(text: "remember me", runner: failing)
        await center.task?.value
        guard case .failed = center.phase else { return XCTFail("expected failed") }

        // retry() reuses the runner+text captured at start.
        center.retry()
        await center.task?.value
        XCTAssertEqual(failing.invocations.count, 2, "retry must re-invoke with the same runner")
    }

    func testDismissClearsTerminalState() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        center.start(text: "x", runner: FakeCLIRunner(stdout: oneTargetJSON()))
        await center.task?.value
        center.dismiss()
        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.result)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter TargetExtractCenterTests 2>test.log; echo "exit=$?"; tail -25 test.log`
Expected: compile failure / FAIL — the phase API and `friendlyMessage` do not exist yet.

- [ ] **Step 4: Rewrite the Center**

Replace `WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift` with:

```swift
import Foundation

/// Abstraction over the two target-extraction completion notifications, so
/// `TargetExtractCenter` can be unit-tested without touching the real
/// `UNUserNotificationCenter` (which has no app-bundle context under
/// `swift test` and crashes if invoked there).
protocol TargetExtractNotifying {
    func sendTargetExtractReadyNotification(count: Int)
    func sendTargetExtractFailedNotification(reason: String)
}

extension NotificationService: TargetExtractNotifying {}

/// App-wide, single-slot registry for the "Extract with AI" target-extraction
/// call. It owns its own cancellable `Task`, so the extraction — and its result
/// — survives the presenting `CreateTargetSheet` being dismissed and any
/// navigation away (the "начал → ушёл → вернулся" contract shared with
/// `MeetingRecorderCenter`). The global `ExtractIndicatorView` capsule reflects
/// `phase` from every screen; there is no wall-clock timeout — the only early
/// stop is `cancel()`, which terminates the CLI subprocess.
@MainActor
@Observable
final class TargetExtractCenter {
    enum Phase: Equatable {
        case idle
        case extracting
        case ready(count: Int)
        case empty
        case failed(message: String, canRetry: Bool)
    }

    private(set) var phase: Phase = .idle
    /// The extracted proposal, set alongside `.ready`. Read by the capsule /
    /// sheet to present `ExtractPreviewSheet`; cleared by `dismiss()`.
    private(set) var result: TargetExtractResult?
    /// Raw CLI stderr behind the friendly `.failed` message, surfaced under the
    /// capsule's "Show details" disclosure. Nil unless the last run failed.
    private(set) var lastRawError: String?

    /// The in-flight extraction. Internal (not private) so tests can await it.
    var task: Task<Void, Never>?

    // Remembered inputs so `retry()` can re-run the same call.
    private var lastText = ""
    private var lastSourceRef = ""
    private var lastRunner: CLIRunnerProtocol?

    private let notificationService: TargetExtractNotifying

    init(notificationService: TargetExtractNotifying = NotificationService.shared) {
        self.notificationService = notificationService
    }

    /// Starts an extraction in the background. No-op while one is already
    /// running (single-slot guard) — the runner is not even invoked.
    func start(text: String, sourceRef: String = "", runner: CLIRunnerProtocol) {
        guard phase != .extracting else { return }
        lastText = text
        lastSourceRef = sourceRef
        lastRunner = runner
        result = nil
        lastRawError = nil
        phase = .extracting
        task = Task { [weak self] in
            await self?.run(text: text, sourceRef: sourceRef, runner: runner)
        }
    }

    /// Cancels the in-flight extraction (terminating the CLI subprocess via
    /// `ProcessCLIRunner`'s cancellation handler) and returns to idle.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        result = nil
    }

    /// Re-runs the last failed extraction with the remembered text + runner.
    func retry() {
        guard case .failed = phase, let runner = lastRunner else { return }
        start(text: lastText, sourceRef: lastSourceRef, runner: runner)
    }

    /// Clears a terminal state (`.ready`/`.empty`/`.failed`) back to idle —
    /// called once a consumer has presented the result or the user dismisses
    /// the capsule.
    func dismiss() {
        task = nil
        phase = .idle
        result = nil
    }

    private func run(text: String, sourceRef: String, runner: CLIRunnerProtocol) async {
        do {
            let extracted = try await TargetExtractService(runner: runner)
                .extract(text: text, sourceRef: sourceRef)
            if Task.isCancelled { return }
            if extracted.extracted.isEmpty {
                phase = .empty
                notificationService.sendTargetExtractFailedNotification(reason: "No targets found in this text")
            } else {
                result = extracted
                phase = .ready(count: extracted.extracted.count)
                notificationService.sendTargetExtractReadyNotification(count: extracted.extracted.count)
            }
        } catch is CancellationError {
            // Cancelled by the user: `cancel()` already reset phase to .idle.
            return
        } catch {
            if Task.isCancelled { return }
            let raw = Self.rawText(for: error)
            lastRawError = raw
            let friendly = Self.friendlyMessage(for: raw)
            phase = .failed(message: friendly.text, canRetry: friendly.canRetry)
            notificationService.sendTargetExtractFailedNotification(reason: friendly.text)
        }
    }

    private static func rawText(for error: Error) -> String {
        if let cliError = error as? CLIRunnerError { return cliError.errorDescription ?? "\(error)" }
        return error.localizedDescription
    }

    /// Maps a raw CLI failure into a human-readable message + whether Retry
    /// makes sense. Never surfaces the raw Go error chain directly (that lives
    /// behind the capsule's "Show details").
    static func friendlyMessage(for raw: String) -> (text: String, canRetry: Bool) {
        let lower = raw.lowercased()
        if lower.contains("deadline exceeded") || lower.contains("timed out") || lower.contains("timeout") {
            return ("Extraction took too long. Try again.", true)
        }
        if lower.contains("not found") {
            return ("Watchtower CLI not found in PATH.", false)
        }
        if lower.contains("network") || lower.contains("connection") || lower.contains("unreachable") {
            return ("Network issue — check your connection and retry.", true)
        }
        if lower.contains("overloaded") || lower.contains("rate limit") {
            return ("AI is busy right now. Try again in a moment.", true)
        }
        return ("Couldn't extract targets. Try again.", true)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter TargetExtractCenterTests 2>test.log; echo "exit=$?"; tail -25 test.log`
Expected: `exit=0`, all `TargetExtractCenterTests` pass. (Capture the real exit code — do not pipe through `tail` for the pass/fail decision; the redirect + `echo exit=$?` above does this.)

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetExtractCenter.swift WatchtowerDesktop/Tests/TargetExtractCenterTests.swift WatchtowerDesktop/Tests/Helpers/FakeCLIRunner.swift
git commit -m "feat(desktop): phase-driven TargetExtractCenter with cancel, retry, friendly errors"
```

---

## Task 4: Swift — ExtractIndicatorView capsule + app-level preview + mount

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Targets/ExtractIndicatorView.swift`
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift:71-73`

**Interfaces:**
- Consumes: `TargetExtractCenter.phase` / `.result` / `.lastRawError` / `cancel()` / `retry()` / `dismiss()` (Task 3); `ExtractPreviewSheet(proposed:omittedCount:notes:onCreateSelected:)`.
- Produces: a global overlay view; no API other consumers depend on.

Views have no unit-test harness in this repo; verification is `swift build` + `/verify` (Task 6 / final). The capsule mirrors `RecordingIndicatorView`'s capsule style exactly.

- [ ] **Step 1: Create the capsule view**

Create `WatchtowerDesktop/Sources/Views/Targets/ExtractIndicatorView.swift`:

```swift
import SwiftUI

/// Global bottom-trailing capsule reflecting `TargetExtractCenter` state, so an
/// in-flight "Extract with AI" run — and its finished result — is visible and
/// actionable from every screen and survives navigation. Hidden when idle.
struct ExtractIndicatorView: View {
    @Environment(AppState.self) private var appState
    @State private var showPreview = false
    @State private var showDetails = false

    var body: some View {
        let center = appState.targetExtractCenter
        content(center)
            // Sit above the recording indicator when both are visible.
            .padding(16)
            .padding(.bottom, 72)
            .sheet(isPresented: $showPreview) {
                if let result = center.result {
                    ExtractPreviewSheet(
                        proposed: result.extracted,
                        omittedCount: result.omittedCount,
                        notes: result.notes
                    ) { _ in
                        center.dismiss()
                    }
                }
            }
    }

    @ViewBuilder
    private func content(_ center: TargetExtractCenter) -> some View {
        switch center.phase {
        case .idle:
            EmptyView()
        case .extracting:
            capsule {
                ProgressView().controlSize(.small)
                Text("Extracting targets…").font(.callout)
                Button("Cancel") { center.cancel() }
                    .controlSize(.small)
            }
        case let .ready(count):
            capsule {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text("^[\(count) target](inflect: true) ready").font(.callout.weight(.medium))
                Button("Review") { showPreview = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Dismiss") { center.dismiss() }
                    .controlSize(.small)
            }
        case .empty:
            capsule {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text("No targets found in this text").font(.callout)
                Button("Dismiss") { center.dismiss() }
                    .controlSize(.small)
            }
        case let .failed(message, canRetry):
            failedCapsule(center, message: message, canRetry: canRetry)
        }
    }

    private func failedCapsule(_ center: TargetExtractCenter, message: String, canRetry: Bool) -> some View {
        capsule {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.callout.weight(.medium))
                if showDetails, let raw = center.lastRawError {
                    Text(raw).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(4)
                } else if center.lastRawError != nil {
                    Button("Show details") { showDetails = true }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if canRetry {
                Button("Retry") { showDetails = false; center.retry() }
                    .controlSize(.small)
            }
            Button("Dismiss") { center.dismiss() }
                .controlSize(.small)
        }
        .frame(maxWidth: 420)
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }
}
```

- [ ] **Step 2: Mount it in WatchtowerApp**

In `WatchtowerDesktop/Sources/App/WatchtowerApp.swift`, immediately after the existing `RecordingIndicatorView` overlay (line 73's closing `}`), add a second overlay:

```swift
                .overlay(alignment: .bottomTrailing) {
                    RecordingIndicatorView()
                }
                .overlay(alignment: .bottomTrailing) {
                    ExtractIndicatorView()
                }
```

(The `.environment(appState)` already applied outermost at line 79 covers both overlays — same reason documented there for `RecordingIndicatorView`.)

- [ ] **Step 3: Build**

Run: `cd WatchtowerDesktop && swift build 2>build.log; echo "exit=$?"; tail -25 build.log`
Expected: `exit=0`. If the `^[...](inflect:)` AttributedString morphology string fails to compile in this toolchain, fall back to `Text(count == 1 ? "1 target ready" : "\(count) targets ready")`.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/ExtractIndicatorView.swift WatchtowerDesktop/Sources/App/WatchtowerApp.swift
git commit -m "feat(desktop): floating ExtractIndicatorView capsule for background extraction"
```

---

## Task 5: Swift — rewire CreateTargetSheet + TargetsListView to the phase API

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetsListView.swift`

**Interfaces:**
- Consumes: `TargetExtractCenter.phase` / `.result` / `dismiss()` / non-async `start(...)` (Task 3).
- Produces: no new API. Removes the old raw-error alert path (now the capsule's job).

- [ ] **Step 1: Update `CreateTargetSheet.extractButton` to the phase API**

In `CreateTargetSheet.swift`, in `extractButton` (lines 156-180), replace the three `center.isRunning` references so the button reads the phase. Change:

```swift
    private var extractButton: some View {
        let center = appState.targetExtractCenter
        return HStack {
            Button {
                Task { await runExtract() }
            } label: {
                if center.isRunning && awaitingOwnExtraction {
```
to:
```swift
    private var extractButton: some View {
        let center = appState.targetExtractCenter
        let isExtracting = center.phase == .extracting
        return HStack {
            Button {
                Task { await runExtract() }
            } label: {
                if isExtracting && awaitingOwnExtraction {
```
and in the same view change `.disabled(center.isRunning || text.trimming…)` to `.disabled(isExtracting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)` and the `.help(center.isRunning && !awaitingOwnExtraction ? …)` to `.help(isExtracting && !awaitingOwnExtraction ? "An extraction is already running — wait for it to finish" : "Run the entered text through the LLM to propose structured targets")`.

- [ ] **Step 2: Make `runExtract()` fire-and-forget**

Replace `runExtract()` (lines 547-555) with:

```swift
    private func runExtract() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        errorMessage = nil
        awaitingOwnExtraction = true
        appState.targetExtractCenter.start(text: text, runner: runner)
    }
```

- [ ] **Step 3: Replace the result-handoff onChange**

Replace the `.onChange(of: appState.targetExtractCenter.isRunning) { … }` block (lines 92-103) with a phase-driven one that only auto-opens the preview while THIS sheet is still up; everything else (empty/failed, or a result the user navigated away from) is surfaced by the global capsule:

```swift
        .onChange(of: appState.targetExtractCenter.phase) { _, phase in
            guard awaitingOwnExtraction else { return }
            switch phase {
            case .ready:
                awaitingOwnExtraction = false
                if let result = appState.targetExtractCenter.result {
                    extractedResult = result
                    showExtractSheet = true
                    // The sheet now owns a copy; clear the Center so the global
                    // capsule doesn't also offer the same result.
                    appState.targetExtractCenter.dismiss()
                }
            case .empty, .failed:
                // Hand off to the global capsule (friendly message + retry).
                awaitingOwnExtraction = false
            case .idle, .extracting:
                break
            }
        }
```

- [ ] **Step 4: Remove the extraction catch-all from TargetsListView**

The global capsule is now the single consumer of extraction results/errors outside the open sheet, so `TargetsListView`'s catch-all (and its raw-text alert — the original bug) is removed. In `TargetsListView.swift`:

1. Delete the three `@State` declarations (lines 10-15): the `showExtractPreview` doc-comment block, `showExtractPreview`, `extractPreviewResult`, and `extractErrorMessage`.
2. In `.onAppear` (line 55) delete the `consumePendingExtraction()` call.
3. Delete the entire `.onChange(of: appState.targetExtractCenter.isRunning) { _, _ in consumePendingExtraction() }` modifier (lines 64-66).
4. Delete the `.sheet(isPresented: $showExtractPreview) { … }` modifier (lines 70-80).
5. Delete the `.alert("Extraction failed", …) { … }` modifier (lines 81-91).
6. Delete the `consumePendingExtraction()` function (lines 131-150).

Leave everything else (create sheet, delete confirmation, `⌘N` shortcut, list/detail) untouched.

- [ ] **Step 5: Build**

Run: `cd WatchtowerDesktop && swift build 2>build.log; echo "exit=$?"; tail -25 build.log`
Expected: `exit=0`, no references to the removed symbols remain.

- [ ] **Step 6: Run the full Desktop test suite**

Run: `cd WatchtowerDesktop && swift test 2>test.log; echo "exit=$?"; tail -30 test.log`
Expected: `exit=0`. (If any other test referenced `TargetExtractCenter.isRunning`/`pendingResult`/`pendingError`, update it to the phase API — grep first: `grep -rn "\.isRunning\|pendingResult\|pendingError" WatchtowerDesktop/Tests`.)

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift WatchtowerDesktop/Sources/Views/Targets/TargetsListView.swift
git commit -m "feat(desktop): rewire target extraction UI to phase-driven capsule"
```

---

## Task 6: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Backend + Desktop gates**

Run:
```bash
go build ./... && go vet ./... && go test ./internal/targets/ ./internal/config/ 2>&1 | tail -20
cd WatchtowerDesktop && swift build 2>build.log; echo "swift-build=$?"; swift test 2>test.log; echo "swift-test=$?"; tail -20 test.log
```
Expected: Go build/vet/tests pass; `swift-build=0`; `swift-test=0`.

- [ ] **Step 2: Drive the real flow (`/verify` skill)**

Build the dev app (`make app-dev`) and exercise: (a) start "Extract with AI" on a target, close the sheet mid-run → capsule shows "Extracting… / Cancel"; on completion → "N targets ready · Review" → Review opens the preview from any screen. (b) Force a failure (e.g. rename the `claude` binary temporarily) → capsule shows a friendly message + Retry, never the raw chain; "Show details" reveals the stderr. (c) Cancel mid-run → capsule disappears, no zombie `watchtower`/`claude` process (`pgrep -fl 'targets extract'` returns nothing). (d) Empty-result text → neutral "No targets found" capsule, no red.

---

## Self-Review

**Spec coverage:**
- No timeout (`<= 0` = no deadline), default 90→0 → Task 1. ✓
- Cancel terminates subprocess → Task 2 (runner) + Task 3 (`cancel()`). ✓
- Phase-driven surviving-state Center → Task 3. ✓
- Floating capsule, app-level preview, mounted globally → Task 4. ✓
- Friendly error mapping + "Show details" → Task 3 (`friendlyMessage`/`lastRawError`) + Task 4 (disclosure). ✓
- Neutral empty state → Task 3 (`.empty`) + Task 4. ✓
- Auto-open preview while sheet open; global capsule otherwise; remove raw alert → Task 5. ✓
- Tests: surviving-state, empty (degenerate clean exit), cancel, retry, Go no-timeout → Tasks 1 & 3. ✓

**Placeholder scan:** none — every code step carries full code.

**Type consistency:** `Phase` cases (`.idle/.extracting/.ready(count:)/.empty/.failed(message:canRetry:)`), `result`, `lastRawError`, `task`, `start`/`cancel`/`retry`/`dismiss`, `friendlyMessage(for:)` are defined in Task 3 and used with the same names/signatures in Tasks 4 & 5. Go `ctxDeadlineGenerator` matches `digest.Generator`. ✓
