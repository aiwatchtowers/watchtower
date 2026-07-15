# WhisperKit Model Prefetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefetch WhisperKit model files before a recording ever starts (Calendar tab open, Settings model change), and show honest download progress, so the model is usually already cached by the time a recording ends.

**Architecture:** A new `TranscriptionModelProvisioner` (`@MainActor @Observable`, held on `AppState`) tracks a `.idle` / `.downloading(progress:)` / `.failed(String)` state, fully decoupled from `MeetingRecorderCenter.Phase`. It is triggered from `CalendarEventsView.onAppear` and the Settings model `Picker`'s `onChange`, and downloads only the model **files** (never instantiates `WhisperKit` — that stays lazy in `MeetingRecorderCenter` as today). `RecordingIndicatorView` renders its state as a second, independent capsule that can appear alongside the existing recording/transcribing capsule.

**Tech Stack:** Swift 5.10, SwiftUI, `@Observable`/`@MainActor`, WhisperKit (SPM), XCTest.

## Global Constraints

- Default model name: `large-v3`, read from the existing `UserDefaults` key `"transcription.model"`. Other valid values: `distil-large-v3`, `medium` (see `SettingsView.swift`'s `Picker`).
- Prefetch triggers are **only**: `CalendarEventsView.onAppear` and the Settings model `Picker`'s `onChange`. Explicitly **no** app-launch prefetch.
- The provisioner downloads model files only — it must never instantiate `WhisperKit` itself (that would double the in-memory model footprint before it's needed).
- `WhisperKit.download` is incremental (already-complete files are skipped) — safe and cheap to call again from `WhisperKitEngine.load` after a prefetch already finished.
- Failure surfaces as an actionable state (Retry + Dismiss); there is no automatic retry/backoff.
- A recording capsule and a model-download capsule may be visible at the same time — they are independent state machines, never merged into one.
- New app-wide service lives in `WatchtowerDesktop/Sources/Services/` (same level as `MeetingRecorderCenter.swift`), following the existing "Center" pattern (constructor-injected dependencies for testability, `private(set)` state).
- Design reference: `docs/superpowers/specs/2026-07-14-model-prefetch-design.md`.

**Known interaction (not a bug to fix in this plan):** `MeetingRecorderCenter.startLivePass` already calls `engineFactory` (and therefore `WhisperKitEngine.load`, therefore a download) the moment a recording starts, showing its own generic `liveEngineState == .loading` spinner. This plan does not touch that indicator. If the provisioner already prefetched the model, that record-start load will simply be fast (an incremental on-disk check). If it didn't finish in time, both the generic live-engine spinner and (if a provisioner download is still in flight) the percentage capsule may be visible together — a minor, acceptable rough edge for v1.

---

### Task 1: Extract `WhisperKitEngine.ensureModelFilesDownloaded`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/WhisperKitEngine.swift:24-41`

**Interfaces:**
- Produces: `WhisperKitEngine.ensureModelFilesDownloaded(modelName: String, downloadProgress: @escaping @Sendable (Double) -> Void) async throws -> URL` — static method, downloads (or confirms already-downloaded) a model's files and returns their local folder URL. Used by Task 2's `TranscriptionModelProvisioner` default `downloadFn`.
- Consumes: nothing new (uses the existing `WhisperKit.download(variant:)` SPM API already called by `load`).

This file wraps real WhisperKit/network calls and — per its own doc comment — is deliberately outside the unit-tested seam (`protocol TranscriptionEngine` is what tests exercise). There is no new automated test for this task; correctness is verified by `swift build` succeeding and `load`'s existing behavior being unchanged (same two `downloadProgress(0)`/`downloadProgress(1)` calls, same `WhisperKitConfig` construction).

- [ ] **Step 1: Extract the download step into its own static method, and have `load` call it**

Replace the current `load` method:

```swift
    /// modelName e.g. "large-v3"; downloadProgress reports 0…1 during first-run model download.
    ///
    /// Uses the explicit download-then-load path because `WhisperKit(WhisperKitConfig(model:))`
    /// offers no download-progress hook in 0.18.0; `WhisperKit.download` is incremental
    /// (already-complete files are skipped), so repeat loads are fast and offline-safe.
    static func load(
        modelName: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperKitEngine {
        downloadProgress(0)
        let modelFolder = try await WhisperKit.download(variant: modelName) { progress in
            downloadProgress(progress.fractionCompleted)
        }
        downloadProgress(1)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            load: true
        )
        let whisperKit = try await WhisperKit(config)
        return WhisperKitEngine(whisperKit: whisperKit)
    }
```

with:

```swift
    /// Downloads `modelName`'s files to the local WhisperKit cache without
    /// instantiating the model. `TranscriptionModelProvisioner` calls this to
    /// prefetch ahead of a recording; `load` below reuses it so the two
    /// callers never diverge on how a download is performed. `WhisperKit.download`
    /// is incremental (already-complete files are skipped), so calling this
    /// again from `load` after a prefetch already finished is a fast on-disk
    /// check, not a re-download.
    static func ensureModelFilesDownloaded(
        modelName: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(variant: modelName) { progress in
            downloadProgress(progress.fractionCompleted)
        }
    }

    /// modelName e.g. "large-v3"; downloadProgress reports 0…1 during first-run model download.
    ///
    /// Uses the explicit download-then-load path because `WhisperKit(WhisperKitConfig(model:))`
    /// offers no download-progress hook in 0.18.0.
    static func load(
        modelName: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperKitEngine {
        downloadProgress(0)
        let modelFolder = try await ensureModelFilesDownloaded(modelName: modelName, downloadProgress: downloadProgress)
        downloadProgress(1)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            load: true
        )
        let whisperKit = try await WhisperKit(config)
        return WhisperKitEngine(whisperKit: whisperKit)
    }
```

- [ ] **Step 2: Verify the project still builds**

Run: `cd WatchtowerDesktop && swift build > /tmp/build.log 2>&1; echo "EXIT: $?"; tail -40 /tmp/build.log`
Expected: `EXIT: 0`, no errors.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/WhisperKitEngine.swift
git commit -m "refactor(transcriber): extract WhisperKitEngine.ensureModelFilesDownloaded

Splits the download step out of load() so a future prefetch path can
reuse it without instantiating WhisperKit itself."
```

---

### Task 2: `TranscriptionModelProvisioner` service with full test coverage

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TranscriptionModelProvisioner.swift`
- Test: `WatchtowerDesktop/Tests/TranscriptionModelProvisionerTests.swift`

**Interfaces:**
- Consumes: `WhisperKitEngine.ensureModelFilesDownloaded(modelName:downloadProgress:) async throws -> URL` (Task 1) as the default `downloadFn`.
- Produces (used by Tasks 3 and 4):
  - `TranscriptionModelProvisioner.State: Equatable` — `.idle`, `.downloading(progress: Double)`, `.failed(String)`.
  - `@MainActor @Observable final class TranscriptionModelProvisioner`, `init(downloadFn: @escaping (String, @escaping @Sendable (Double) -> Void) async throws -> Void = ...)`.
  - `var state: State` (read-only outside the class).
  - `func ensureDownloaded(modelName: String)` — fire-and-forget; starts/joins/supersedes a download.
  - `func retry()` — no-op unless `.failed`.
  - `func dismiss()` — no-op unless `.failed`.

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/TranscriptionModelProvisionerTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

// MARK: - Fakes

/// Blocks each `call` until the test releases it (keyed by model name, so two
/// models can be in flight at once — e.g. a superseded download and the one
/// that replaced it). Signals entry via `enteredStream` so tests can
/// deterministically observe state at each step without racing the async work.
private final class GateDownloader: @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var calledModels: [String] = []
    let enteredStream: AsyncStream<String>

    private let enteredContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var pendingContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var queuedResults: [String: Result<Void, Error>] = [:]

    init() {
        (enteredStream, enteredContinuation) = AsyncStream<String>.makeStream()
    }

    func call(modelName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.lock()
        callCount += 1
        calledModels.append(modelName)
        lock.unlock()
        enteredContinuation.yield(modelName)
        progress(0.5)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let queued = queuedResults.removeValue(forKey: modelName) {
                lock.unlock()
                continuation.resume(with: queued)
            } else {
                pendingContinuations[modelName] = continuation
                lock.unlock()
            }
        }
    }

    /// Lets the currently-blocked (or next) call for `modelName` return.
    func release(_ modelName: String, error: Error? = nil) {
        lock.lock()
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        if let continuation = pendingContinuations.removeValue(forKey: modelName) {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            queuedResults[modelName] = result
            lock.unlock()
        }
    }
}

private struct FakeDownloadError: Error, LocalizedError {
    var errorDescription: String? { "network unreachable" }
}

// MARK: - Tests

@MainActor
final class TranscriptionModelProvisionerTests: XCTestCase {

    /// Drains the main actor so the provisioner's stream-backed state updates
    /// (yielded from the detached download task) have been applied.
    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    func testDownloadingReportsProgressThenIdleOnSuccess() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)

        provisioner.ensureDownloaded(modelName: "large-v3")
        var entered = downloader.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        await drainMainActor()

        guard case .downloading(let progress) = provisioner.state else {
            return XCTFail("expected .downloading, got \(provisioner.state)")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.0001)

        downloader.release("large-v3")
        await provisioner.currentTask?.value

        XCTAssertEqual(provisioner.state, .idle)
        XCTAssertEqual(downloader.calledModels, ["large-v3"])
    }

    func testSameModelWhileDownloadingIsANoOp() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)

        provisioner.ensureDownloaded(modelName: "large-v3")
        var entered = downloader.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        await drainMainActor()

        provisioner.ensureDownloaded(modelName: "large-v3")

        XCTAssertEqual(downloader.callCount, 1, "a duplicate request for the same in-flight model must be a no-op")

        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testDifferentModelSupersedesInFlightDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(modelName: "large-v3")
        _ = await entered.next()
        await drainMainActor()
        let staleTask = provisioner.currentTask

        provisioner.ensureDownloaded(modelName: "distil-large-v3")
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(downloader.calledModels, ["large-v3", "distil-large-v3"])
        guard case .downloading = provisioner.state else {
            return XCTFail("expected .downloading for the new model, got \(provisioner.state)")
        }

        // The stale large-v3 call finishing later must not resurrect its outcome.
        downloader.release("large-v3")
        await staleTask?.value
        await drainMainActor()
        guard case .downloading = provisioner.state else {
            return XCTFail(".downloading for the current model must survive the stale download completing, got \(provisioner.state)")
        }

        downloader.release("distil-large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testFailureSurfacesMessageAndRetryReDownloadsSameModel() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(modelName: "large-v3")
        _ = await entered.next()
        await drainMainActor()

        downloader.release("large-v3", error: FakeDownloadError())
        await provisioner.currentTask?.value

        guard case .failed(let message) = provisioner.state else {
            return XCTFail("expected .failed, got \(provisioner.state)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("network unreachable"))

        provisioner.retry()
        _ = await entered.next()
        await drainMainActor()
        guard case .downloading = provisioner.state else {
            return XCTFail("retry must re-download the same model, got \(provisioner.state)")
        }
        XCTAssertEqual(downloader.calledModels, ["large-v3", "large-v3"])

        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testDismissClearsFailedStateWithoutRetrying() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(modelName: "large-v3")
        _ = await entered.next()
        await drainMainActor()

        downloader.release("large-v3", error: FakeDownloadError())
        await provisioner.currentTask?.value

        guard case .failed = provisioner.state else {
            return XCTFail("expected .failed, got \(provisioner.state)")
        }

        provisioner.dismiss()
        XCTAssertEqual(provisioner.state, .idle)
        XCTAssertEqual(downloader.callCount, 1, "dismiss must not trigger a retry")
    }

    func testAlreadySucceededModelIsNotReDownloaded() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(modelName: "large-v3")
        _ = await entered.next()
        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)

        // e.g. reopening the Calendar tab after the model already downloaded.
        provisioner.ensureDownloaded(modelName: "large-v3")

        XCTAssertEqual(downloader.callCount, 1, "re-requesting an already-downloaded model must not re-trigger a download")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail (the type doesn't exist yet)**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionModelProvisionerTests > /tmp/test.log 2>&1; echo "EXIT: $?"; tail -40 /tmp/test.log`
Expected: build failure — `cannot find type 'TranscriptionModelProvisioner' in scope` (or similar).

- [ ] **Step 3: Implement `TranscriptionModelProvisioner`**

Create `WatchtowerDesktop/Sources/Services/TranscriptionModelProvisioner.swift`:

```swift
import Foundation

/// App-wide registry for prefetching WhisperKit model files ahead of a
/// recording, so `MeetingRecorderCenter`'s engine load (at record-start, and
/// again at transcribe-time as a fallback) usually hits an already-warm
/// on-disk cache instead of paying for the download right when the user is
/// waiting on a transcript.
///
/// Decoupled from `MeetingRecorderCenter.Phase` on purpose: a recording never
/// depends on WhisperKit, so a download can be in flight (or failed) while a
/// recording is independently in progress — one state machine can't
/// represent both without an artificial precedence between them.
@MainActor
@Observable
final class TranscriptionModelProvisioner {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The model the current/last `ensureDownloaded` call targets. A stale
    /// call's progress/outcome is checked against this and dropped once a
    /// different model has been requested.
    private(set) var currentModelName: String?
    /// The model whose files are already confirmed on disk from a prior
    /// successful prefetch — re-requesting it is a no-op, so reopening the
    /// Calendar tab doesn't re-hit the network every time.
    private var lastSucceededModel: String?

    private(set) var currentTask: Task<Void, Never>?

    private let downloadFn: (String, @escaping @Sendable (Double) -> Void) async throws -> Void

    init(
        downloadFn: @escaping (String, @escaping @Sendable (Double) -> Void) async throws -> Void = { modelName, progress in
            _ = try await WhisperKitEngine.ensureModelFilesDownloaded(modelName: modelName, downloadProgress: progress)
        }
    ) {
        self.downloadFn = downloadFn
    }

    /// Starts (or joins) the download of `modelName`'s files. No-op if that
    /// exact model is already downloading or already succeeded. Supersedes
    /// any in-flight download of a different model — best-effort only: the
    /// superseded download may keep running in the background, but its
    /// progress/outcome is dropped once superseded.
    func ensureDownloaded(modelName: String) {
        if case .downloading = state, currentModelName == modelName {
            return
        }
        if case .idle = state, lastSucceededModel == modelName {
            return
        }

        currentTask?.cancel()
        currentModelName = modelName
        state = .downloading(progress: 0)

        currentTask = Task { [weak self, downloadFn] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<Double>.makeStream()
            let work = Task.detached {
                do {
                    try await downloadFn(modelName) { progress in continuation.yield(progress) }
                    continuation.finish()
                    return Result<Void, Error>.success(())
                } catch {
                    continuation.finish()
                    return .failure(error)
                }
            }
            for await progress in stream {
                guard self.currentModelName == modelName else { continue }
                self.state = .downloading(progress: progress)
            }
            guard self.currentModelName == modelName else { return }
            switch await work.value {
            case .success:
                self.lastSucceededModel = modelName
                self.state = .idle
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-attempts the download for the model that just failed. No-op unless
    /// `state` is `.failed`.
    func retry() {
        guard case .failed = state, let modelName = currentModelName else { return }
        ensureDownloaded(modelName: modelName)
    }

    /// Clears a `.failed` state without retrying — the next natural trigger
    /// (reopening Calendar, re-selecting the model in Settings) tries again.
    func dismiss() {
        guard case .failed = state else { return }
        state = .idle
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptionModelProvisionerTests > /tmp/test.log 2>&1; echo "EXIT: $?"; tail -60 /tmp/test.log`
Expected: `EXIT: 0`, all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TranscriptionModelProvisioner.swift WatchtowerDesktop/Tests/TranscriptionModelProvisionerTests.swift
git commit -m "feat(transcriber): TranscriptionModelProvisioner for model prefetch

New app-wide service that downloads WhisperKit model files ahead of a
recording, decoupled from MeetingRecorderCenter's phase so a download
and a recording can be in flight independently."
```

---

### Task 3: Wire the provisioner into AppState and its two triggers

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift:38`
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift:4-12,36`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift:442-447`

**Interfaces:**
- Consumes: `TranscriptionModelProvisioner` (Task 2).
- Produces: `appState.transcriptionModelProvisioner`, read by Task 4's `RecordingIndicatorView`.

No new automated tests — these are one-line wiring changes with no new branching logic to unit test (the tested behavior lives entirely in Task 2's `TranscriptionModelProvisioner`). Verified by build + the manual acceptance pass in Task 5.

- [ ] **Step 1: Add the provisioner to `AppState`**

In `WatchtowerDesktop/Sources/App/AppState.swift`, right after the existing `meetingRecorderCenter` declaration:

```swift
    /// App-wide, single-slot registry for meeting recording + transcription, so
    /// an in-flight recording and its transcription survive navigating away from
    /// the calendar event that started it.
    let meetingRecorderCenter = MeetingRecorderCenter()

    /// App-wide registry of in-flight/failed WhisperKit model-file prefetches,
    /// so download progress is visible (and retryable) from anywhere,
    /// independent of whether a recording is in progress.
    let transcriptionModelProvisioner = TranscriptionModelProvisioner()
```

- [ ] **Step 2: Trigger a prefetch when the Calendar tab appears**

In `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift`, add an `@AppStorage` property alongside the existing `@State` ones (after line 4's `appState` declaration):

```swift
struct CalendarEventsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("transcription.model") private var transcriptionModel = "large-v3"
    @State private var meetingPrepVM = MeetingPrepViewModel()
```

Then change the existing `.onAppear` (currently `.onAppear { calVM.loadEvents() }`):

```swift
                .onAppear {
                    calVM.loadEvents()
                    appState.transcriptionModelProvisioner.ensureDownloaded(modelName: transcriptionModel)
                }
```

- [ ] **Step 3: Trigger a prefetch when the model is changed in Settings**

In `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift`, inside `transcriptionSection` (the `GeneralSettings` struct already has `@Environment(AppState.self) private var appState` at line 34), change the `Picker`:

```swift
            Picker("Model", selection: $transcriptionModel) {
                Text("Large v3 (best quality)").tag("large-v3")
                Text("Distil Large v3 (faster)").tag("distil-large-v3")
                Text("Medium (fastest)").tag("medium")
            }
            .help("WhisperKit model used for on-device transcription")
            .onChange(of: transcriptionModel) { _, newValue in
                appState.transcriptionModelProvisioner.ensureDownloaded(modelName: newValue)
            }
```

- [ ] **Step 4: Verify the project builds**

Run: `cd WatchtowerDesktop && swift build > /tmp/build.log 2>&1; echo "EXIT: $?"; tail -40 /tmp/build.log`
Expected: `EXIT: 0`, no errors.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift
git commit -m "feat(transcriber): trigger model prefetch from Calendar tab and Settings

Opening the Calendar tab or picking a different model in Settings now
starts (or joins) a TranscriptionModelProvisioner download immediately,
instead of waiting for the model to be needed at record-start/stop."
```

---

### Task 4: Render the download capsule in `RecordingIndicatorView`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/RecordingIndicatorView.swift:11-37`

**Interfaces:**
- Consumes: `appState.transcriptionModelProvisioner.state` (Task 2/3), `TranscriptionModelProvisioner.retry()`, `TranscriptionModelProvisioner.dismiss()`.

No new automated test for this task — there is no existing test file for `RecordingIndicatorView` today (its other capsule states, e.g. `.failed`/`.transcribing`, aren't unit-tested either, since the view reads `@Environment(AppState.self)` directly). Verified by build + the manual acceptance pass in Task 5.

- [ ] **Step 1: Split the existing `body` switch into a helper, and add the provisioner capsule**

Replace the current `body`:

```swift
    var body: some View {
        let center = appState.meetingRecorderCenter
        Group {
            switch center.phase {
            case .idle:
                if center.pendingAudioURL != nil {
                    recoveredPill(center)
                }
            case let .recording(startedAt):
                recordingView(center, startedAt: startedAt)
            case let .transcribing(done, total):
                capsule {
                    ProgressView().controlSize(.small)
                    Text(total > 0 ? "Transcribing \(done)/\(total)" : "Transcribing…")
                        .font(.callout)
                }
            case .summarizing:
                capsule {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(.callout)
                }
            case let .failed(message):
                failedCapsule(center, message: message)
            }
        }
        .padding(16)
    }
```

with:

```swift
    var body: some View {
        let center = appState.meetingRecorderCenter
        let provisioner = appState.transcriptionModelProvisioner
        VStack(alignment: .trailing, spacing: 10) {
            recorderContent(center)
            provisionerContent(provisioner)
        }
        .padding(16)
    }

    @ViewBuilder
    private func recorderContent(_ center: MeetingRecorderCenter) -> some View {
        switch center.phase {
        case .idle:
            if center.pendingAudioURL != nil {
                recoveredPill(center)
            }
        case let .recording(startedAt):
            recordingView(center, startedAt: startedAt)
        case let .transcribing(done, total):
            capsule {
                ProgressView().controlSize(.small)
                Text(total > 0 ? "Transcribing \(done)/\(total)" : "Transcribing…")
                    .font(.callout)
            }
        case .summarizing:
            capsule {
                ProgressView().controlSize(.small)
                Text("Summarizing…").font(.callout)
            }
        case let .failed(message):
            failedCapsule(center, message: message)
        }
    }

    @ViewBuilder
    private func provisionerContent(_ provisioner: TranscriptionModelProvisioner) -> some View {
        switch provisioner.state {
        case .idle:
            EmptyView()
        case let .downloading(progress):
            capsule {
                ProgressView(value: progress).controlSize(.small).frame(width: 80)
                Text("Downloading model… \(Int(progress * 100))%").font(.callout)
            }
        case let .failed(message):
            modelFailedCapsule(provisioner, message: message)
        }
    }

    private func modelFailedCapsule(_ provisioner: TranscriptionModelProvisioner, message: String) -> some View {
        capsule {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Model download failed").font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Retry") { provisioner.retry() }
                .controlSize(.small)
            Button("Dismiss") { provisioner.dismiss() }
                .controlSize(.small)
        }
        .frame(maxWidth: 380)
    }
```

Leave every other method in the file (`recordingView`, `recordingCapsule`, `liveEngineIndicator`, `expandedPanel`, `liveTranscriptBody`, `failedCapsule`, `recoveredPill`, `stop`, `retry`, `capsule`, `elapsed`) untouched.

- [ ] **Step 2: Verify the project builds**

Run: `cd WatchtowerDesktop && swift build > /tmp/build.log 2>&1; echo "EXIT: $?"; tail -40 /tmp/build.log`
Expected: `EXIT: 0`, no errors.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/RecordingIndicatorView.swift
git commit -m "feat(transcriber): show model-download progress as its own capsule

RecordingIndicatorView now renders TranscriptionModelProvisioner's
state independently of MeetingRecorderCenter's phase, so a real
download percentage (with Retry/Dismiss on failure) is visible even
while a recording is separately in progress."
```

---

### Task 5: Full-suite verification + manual acceptance

**Files:** none (verification only).

- [ ] **Step 1: Run the full Swift test suite with a real exit code check**

Run: `cd WatchtowerDesktop && swift test > /tmp/full-test.log 2>&1; echo "EXIT: $?"; tail -60 /tmp/full-test.log`
Expected: `EXIT: 0`.

- [ ] **Step 2: Run `swift build` once more for the release-adjacent debug build**

Run: `cd WatchtowerDesktop && swift build > /tmp/build.log 2>&1; echo "EXIT: $?"; tail -40 /tmp/build.log`
Expected: `EXIT: 0`.

- [ ] **Step 3: Manual acceptance in the running app**

Per `CLAUDE.md`'s UI-verification rule, build and run the app (`make app-dev` or the project's existing dev-run flow) and check:

- Open the Calendar tab on a machine where the configured model isn't fully cached (or delete `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>` first) → a "Downloading model… N%" capsule appears with a real, increasing percentage.
- While it's downloading, start and stop a recording → the recording capsule and the download capsule are both visible at once; after the download finishes, the download capsule disappears.
- In Settings, switch the transcription model to a different one → a new download capsule starts for the new model.
- Reopen the Calendar tab after a model has already fully downloaded → no new download capsule appears (no redundant network hit).
- Disconnect the network, then reopen the Calendar tab (or switch models) → the capsule shows "Model download failed" with Retry/Dismiss; reconnect network and press Retry → it succeeds.

- [ ] **Step 4: Report results**

If all checks pass, the feature is complete — no commit needed for this task (verification only, no file changes).
