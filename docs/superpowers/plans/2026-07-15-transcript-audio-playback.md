# Transcript Text + Audio Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user read the full transcript text and play back the source audio for both ad-hoc and event-linked meeting recordings in the Desktop app.

**Architecture:** A new `AudioPlaybackCenter` (`@Observable`, AppState-held, single active `AVAudioPlayer` behind a testable `AudioPlayback` protocol) backs a new reusable `AudioPlayerControlView` (play/pause + scrubber). A `TranscriptAudioControl` wrapper renders that control or a "Recording deleted" caption depending on `audioPath`. `CalendarEventsView.adHocRow` becomes an expandable `DisclosureGroup` (mirroring `TranscriptSectionView.transcriptRow`, which already shows full text) so both entry points get text + playback. Shared formatting logic (`formatDuration`/`formattedDate`/lang badges), currently duplicated between the two views, is extracted first.

**Tech Stack:** Swift 5.10, SwiftUI, `@Observable` (Swift Observation framework), AVFoundation (`AVAudioPlayer`), XCTest, ViewInspector (view-level tests), GRDB (unrelated to this feature but present in the same module).

**Design doc:** `docs/superpowers/specs/2026-07-15-transcript-audio-playback-design.md`

## Global Constraints

- macOS 14+ (`Package.swift` platform floor) — no availability guards needed beyond that.
- `@MainActor` + `@Observable` on every new Center class, matching `MeetingRecorderCenter`/`TargetExtractCenter`.
- Single active audio player app-wide: starting playback on one row always stops any other row's playback first (confirmed design decision — not independent simultaneous players).
- No changes to the Go/CLI side, `meeting_transcripts` schema, or the audio retention sweep.
- Tests: XCTest, `@testable import WatchtowerDesktop`; view-level tests use `ViewInspector` (`import ViewInspector`) only for views that don't require `@Environment(AppState.self)` — this is why `AudioPlayerControlView` and `TranscriptAudioControl` take their dependencies as explicit `let` properties instead of reading `@Environment`.
- Run Swift tests with: `cd WatchtowerDesktop && swift build && swift test 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"` — always check the real exit code from the tee'd log, never truncate through `tail`.
- Commit after each task with `git add <specific files>` (never `-A`/`.`).
- **Pre-existing dirty state:** at the time this plan was written, `git status` showed uncommitted changes to `WatchtowerApp.swift`, `MeetingRecorderCenter.swift`, `CalendarEventsView.swift`, `SettingsView.swift`, `docs/app-guide.md`, and `docs/legal/google-verification.md` from earlier, unrelated session work (default-transcription-model change, environment-modifier ordering fix). This plan's tasks also touch `CalendarEventsView.swift`. Before starting Task 1, either commit that pre-existing work separately or confirm with the user how to handle it — otherwise a plain `git add WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift` in Task 1/Task 7 will bundle those unrelated changes into this feature's commits. Check `git diff` on each file this plan modifies before its first `git add` in this plan, and if it contains hunks this plan didn't just write, stop and ask rather than committing them silently.

---

### Task 1: Extract shared transcript formatting helpers

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Calendar/TranscriptFormatting.swift`
- Create: `WatchtowerDesktop/Tests/TranscriptFormattingTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift`

**Interfaces:**
- Produces: `enum TranscriptFormatting { static func formatDuration(_ seconds: Int) -> String; static func formattedDate(_ iso: String) -> String; static func decodeLangStats(_ json: String) -> [(String, Int)] }` and `struct TranscriptLangBadges: View { let langStatsJSON: String }` — both used by later tasks and by the two existing views.

`formatDuration`, `formattedDate`, and `decodeLangStats`/the lang-badge rendering currently exist twice (verbatim) in `TranscriptSectionView` and `CalendarEventsView`. This task moves them to one shared file with no behavior change, and is pure setup for Task 6/7 (which will call `TranscriptFormatting.*` from both views instead of re-duplicating them a third time in the ad-hoc row's new expanded content).

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/TranscriptFormattingTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class TranscriptFormattingTests: XCTestCase {
    func test_formatDurationUnderAMinute() {
        XCTAssertEqual(TranscriptFormatting.formatDuration(45), "45s")
    }

    func test_formatDurationOverAMinute() {
        XCTAssertEqual(TranscriptFormatting.formatDuration(125), "2m 5s")
    }

    func test_formatDurationZero() {
        XCTAssertEqual(TranscriptFormatting.formatDuration(0), "0s")
    }

    func test_formattedDateParsesISO8601() {
        let result = TranscriptFormatting.formattedDate("2026-07-15T10:30:00Z")
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, "2026-07-15T10:30:00Z")
    }

    func test_formattedDateFallsBackToRawStringWhenUnparseable() {
        XCTAssertEqual(TranscriptFormatting.formattedDate("not-a-date"), "not-a-date")
    }

    func test_decodeLangStatsSortsDescendingByCount() {
        let json = #"{"en":2,"ru":5,"uk":1}"#
        let result = TranscriptFormatting.decodeLangStats(json)
        XCTAssertEqual(result.map(\.0), ["ru", "en", "uk"])
        XCTAssertEqual(result.map(\.1), [5, 2, 1])
    }

    func test_decodeLangStatsReturnsEmptyForInvalidJSON() {
        XCTAssertTrue(TranscriptFormatting.decodeLangStats("not json").isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptFormattingTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: build FAILS — `TranscriptFormatting` does not exist yet.

- [ ] **Step 3: Create the shared formatting file**

Create `WatchtowerDesktop/Sources/Views/Calendar/TranscriptFormatting.swift`:

```swift
import Foundation
import SwiftUI

/// Shared formatting for meeting-transcript rows, used by both
/// `TranscriptSectionView` (event-linked recordings) and `CalendarEventsView`
/// (ad-hoc recordings) so duration/date/language-badge rendering can't drift
/// between the two entry points.
enum TranscriptFormatting {
    static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    static func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func decodeLangStats(_ json: String) -> [(String, Int)] {
        guard let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return []
        }
        return stats.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

/// Per-language window-count badges (e.g. "RU 4  EN 2") for a transcript's
/// `langStats` JSON blob.
struct TranscriptLangBadges: View {
    let langStatsJSON: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TranscriptFormatting.decodeLangStats(langStatsJSON), id: \.0) { lang, count in
                Text("\(lang.uppercased()) \(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1), in: Capsule())
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptFormattingTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: all 6 tests PASS, EXIT: 0.

- [ ] **Step 5: Wire `TranscriptSectionView` to the shared helpers**

In `WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift`, replace the `transcriptRow` function's use of the local `langBadges(transcript)` call and the three now-duplicated private funcs at the bottom of the file.

Replace:
```swift
    private func transcriptRow(_ transcript: MeetingTranscript) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                langBadges(transcript)
```
with:
```swift
    private func transcriptRow(_ transcript: MeetingTranscript) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TranscriptLangBadges(langStatsJSON: transcript.langStats)
```

Replace:
```swift
        } label: {
            HStack(spacing: 8) {
                Text(formatDuration(transcript.durationSec))
                    .font(.callout)
                Text(formattedDate(transcript.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func langBadges(_ transcript: MeetingTranscript) -> some View {
        HStack(spacing: 6) {
            ForEach(decodeLangStats(transcript.langStats), id: \.0) { lang, count in
                Text("\(lang.uppercased()) \(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1), in: Capsule())
            }
        }
    }
```
with:
```swift
        } label: {
            HStack(spacing: 8) {
                Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                    .font(.callout)
                Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
```

Replace (at the bottom of the file, the now-orphaned helpers plus the closing brace):
```swift
    private func decodeLangStats(_ json: String) -> [(String, Int)] {
        guard let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return []
        }
        return stats.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
```
with just:
```swift
}
```

- [ ] **Step 6: Wire `CalendarEventsView` to the shared helpers**

In `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift`, the `adHocRow` function calls the local `formattedDate`/`formatDuration`. Replace:
```swift
                HStack(spacing: 8) {
                    Text(formattedDate(transcript.createdAt))
                    Text(formatDuration(transcript.durationSec))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
```
with:
```swift
                HStack(spacing: 8) {
                    Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                    Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
```

Then remove the now-unused private helpers. Replace:
```swift
    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Empty
```
with:
```swift
    // MARK: - Empty
```

- [ ] **Step 7: Build and run the full test suite to confirm nothing broke**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/swift-build.log; echo "EXIT: $?"`
Expected: EXIT: 0, no "ambiguous use" or "cannot find" errors.

Run: `cd WatchtowerDesktop && swift test 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: EXIT: 0, all existing tests still pass alongside the new `TranscriptFormattingTests`.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/TranscriptFormatting.swift \
        WatchtowerDesktop/Tests/TranscriptFormattingTests.swift \
        WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift \
        WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift
git commit -m "refactor(transcriber): dedupe transcript formatting into TranscriptFormatting"
```

---

### Task 2: `AudioPlaybackCenter`

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/AudioPlaybackCenter.swift`
- Create: `WatchtowerDesktop/Tests/AudioPlaybackCenterTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `protocol AudioPlayback: AnyObject { var currentTime: TimeInterval { get set }; var duration: TimeInterval { get }; var isPlaying: Bool { get }; @discardableResult func play() -> Bool; func pause(); func stop() }`, `extension AVAudioPlayer: AudioPlayback {}`, and `@MainActor @Observable final class AudioPlaybackCenter` with:
  - `init(playerFactory: @escaping (URL) throws -> AudioPlayback = { try AVAudioPlayer(contentsOf: $0) })`
  - `private(set) var activeTranscriptID: Int64?`
  - `private(set) var failedTranscriptID: Int64?`
  - `private(set) var errorMessage: String?`
  - `private(set) var isPlaying: Bool`
  - `private(set) var currentTime: TimeInterval`
  - `private(set) var duration: TimeInterval`
  - `func play(url: URL, transcriptID: Int64)`
  - `func pause()`
  - `func resume()`
  - `func seek(to time: TimeInterval)`
  - `func refreshProgress()` — not `private`, so tests can drive it directly instead of spinning a `RunLoop` for the real `Timer`.
  These exact names/types are consumed by Task 4 (`AudioPlayerControlView`).

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/AudioPlaybackCenterTests.swift`:

```swift
import Foundation
import XCTest
@testable import WatchtowerDesktop

private final class FakePlayback: AudioPlayback {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval
    private(set) var isPlaying = false
    private(set) var playCalls = 0
    private(set) var stopCalls = 0

    init(duration: TimeInterval = 10) {
        self.duration = duration
    }

    @discardableResult
    func play() -> Bool {
        playCalls += 1
        isPlaying = true
        return true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        stopCalls += 1
        isPlaying = false
    }
}

private struct FakePlaybackError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class AudioPlaybackCenterTests: XCTestCase {
    func test_playSetsActiveAndStartsPlaying() {
        let fake = FakePlayback(duration: 20)
        let center = AudioPlaybackCenter(playerFactory: { _ in fake })

        center.play(url: URL(fileURLWithPath: "/tmp/rec1.caf"), transcriptID: 1)

        XCTAssertEqual(center.activeTranscriptID, 1)
        XCTAssertTrue(center.isPlaying)
        XCTAssertEqual(center.duration, 20)
        XCTAssertEqual(fake.playCalls, 1)
    }

    func test_playingSecondRecordingStopsFirst() {
        let first = FakePlayback()
        let second = FakePlayback()
        var call = 0
        let center = AudioPlaybackCenter(playerFactory: { _ in
            call += 1
            return call == 1 ? first : second
        })

        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        center.play(url: URL(fileURLWithPath: "/tmp/b.caf"), transcriptID: 2)

        XCTAssertEqual(first.stopCalls, 1)
        XCTAssertEqual(center.activeTranscriptID, 2)
        XCTAssertTrue(center.isPlaying)
    }

    func test_playFailureSurfacesErrorWithoutRestoringPrevious() {
        let good = FakePlayback()
        var alreadyPlayed = false
        let center = AudioPlaybackCenter(playerFactory: { _ in
            if alreadyPlayed { throw FakePlaybackError() }
            alreadyPlayed = true
            return good
        })

        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        center.play(url: URL(fileURLWithPath: "/tmp/bad.caf"), transcriptID: 2)

        XCTAssertNil(center.activeTranscriptID)
        XCTAssertEqual(center.failedTranscriptID, 2)
        XCTAssertEqual(center.errorMessage, "boom")
        XCTAssertFalse(center.isPlaying)
    }

    func test_pauseStopsPlayingWithoutClearingActive() {
        let fake = FakePlayback()
        let center = AudioPlaybackCenter(playerFactory: { _ in fake })
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)

        center.pause()

        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.activeTranscriptID, 1)
        XCTAssertFalse(fake.isPlaying)
    }

    func test_resumeAfterPauseReusesSamePlayerNotFactory() {
        var factoryCalls = 0
        let fake = FakePlayback()
        let center = AudioPlaybackCenter(playerFactory: { _ in
            factoryCalls += 1
            return fake
        })
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        center.pause()

        center.resume()

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(center.isPlaying)
        XCTAssertEqual(fake.playCalls, 2)
    }

    func test_resumeAfterNaturalFinishRestartsFromZero() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter(playerFactory: { _ in fake })
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        fake.currentTime = 10
        fake.pause() // simulates AVAudioPlayer's own isPlaying flipping false at natural end
        center.refreshProgress()

        center.resume()

        XCTAssertEqual(fake.currentTime, 0)
        XCTAssertEqual(center.currentTime, 0)
        XCTAssertTrue(center.isPlaying)
    }

    func test_seekClampsToDurationRange() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter(playerFactory: { _ in fake })
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)

        center.seek(to: 999)
        XCTAssertEqual(center.currentTime, 10)

        center.seek(to: -5)
        XCTAssertEqual(center.currentTime, 0)
    }

    // Degenerate: no active player yet — every control must no-op, not crash.
    func test_operationsWithNoActivePlayerAreNoops() {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })

        center.pause()
        center.resume()
        center.seek(to: 5)
        center.refreshProgress()

        XCTAssertNil(center.activeTranscriptID)
        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.currentTime, 0)
    }

    func test_refreshProgressReadsCurrentTimeFromPlayer() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter(playerFactory: { _ in fake })
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        fake.currentTime = 4.5

        center.refreshProgress()

        XCTAssertEqual(center.currentTime, 4.5)
    }

    func test_refreshProgressDetectsNaturalFinish() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter(playerFactory: { _ in fake })
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        fake.currentTime = 10
        fake.pause() // simulates the player's own isPlaying flipping false, not a user pause

        center.refreshProgress()

        XCTAssertFalse(center.isPlaying)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter AudioPlaybackCenterTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: build FAILS — `AudioPlaybackCenter`/`AudioPlayback` do not exist yet.

- [ ] **Step 3: Implement `AudioPlaybackCenter`**

Create `WatchtowerDesktop/Sources/Services/AudioPlaybackCenter.swift`:

```swift
import Foundation
import AVFoundation

/// Abstraction over `AVAudioPlayer`'s playback surface, so `AudioPlaybackCenter`
/// is unit-testable without touching real audio hardware/files.
protocol AudioPlayback: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioPlayback {}

/// App-wide, single-slot registry for meeting-recording audio playback.
///
/// Only one recording plays at a time app-wide — starting a new `play()`
/// always stops/releases whatever was playing first. State lives here (never
/// view-local) so playback for a transcript row behaves consistently
/// regardless of which view embeds its control, matching the
/// `MeetingRecorderCenter`/`TargetExtractCenter` "survives navigation" pattern.
@MainActor
@Observable
final class AudioPlaybackCenter {
    /// The transcript whose audio is loaded (playing or paused). `nil` when idle.
    private(set) var activeTranscriptID: Int64?
    /// The transcript whose most recent `play()` attempt failed to load.
    /// Cleared on the next successful `play()`.
    private(set) var failedTranscriptID: Int64?
    private(set) var errorMessage: String?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AudioPlayback?
    private var timer: Timer?
    private let playerFactory: (URL) throws -> AudioPlayback

    init(playerFactory: @escaping (URL) throws -> AudioPlayback = { try AVAudioPlayer(contentsOf: $0) }) {
        self.playerFactory = playerFactory
    }

    /// Loads `url` and starts playing immediately, stopping any currently
    /// active playback first (single-active invariant). On failure the
    /// previous playback stays stopped — it is not restored — and
    /// `failedTranscriptID`/`errorMessage` surface the problem to whichever
    /// row attempted it.
    func play(url: URL, transcriptID: Int64) {
        stopCurrent()
        do {
            let newPlayer = try playerFactory(url)
            player = newPlayer
            activeTranscriptID = transcriptID
            failedTranscriptID = nil
            errorMessage = nil
            duration = newPlayer.duration
            currentTime = 0
            newPlayer.play()
            isPlaying = true
            startTimer()
        } catch {
            player = nil
            activeTranscriptID = nil
            failedTranscriptID = transcriptID
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    /// Pauses the active player without releasing it — `resume()` continues
    /// from the same position. No-op when nothing is active.
    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        stopTimer()
    }

    /// Resumes the active (paused) player. If it already finished playing
    /// naturally (`currentTime` caught up to `duration`), restarts from 0
    /// instead of a silent no-op replay. No-op when nothing is active.
    func resume() {
        guard let player else { return }
        if duration > 0 && currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    /// Seeks the active player, clamped to `[0, duration]`. No-op when
    /// nothing is active.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Pulls `currentTime` from the active player and detects natural
    /// end-of-playback (the player stopped itself without `pause()` being
    /// called). Driven by a timer during real playback; exposed (not
    /// `private`) so tests can call it directly instead of spinning a
    /// `RunLoop` to let a real `Timer` fire.
    func refreshProgress() {
        guard let player else { return }
        currentTime = player.currentTime
        if isPlaying && !player.isPlaying {
            isPlaying = false
            stopTimer()
        }
    }

    private func stopCurrent() {
        player?.stop()
        player = nil
        activeTranscriptID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter AudioPlaybackCenterTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: all 10 tests PASS, EXIT: 0.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/AudioPlaybackCenter.swift \
        WatchtowerDesktop/Tests/AudioPlaybackCenterTests.swift
git commit -m "feat(transcriber): add AudioPlaybackCenter for single-slot audio playback"
```

---

### Task 3: Wire `AudioPlaybackCenter` into `AppState`

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift:35-43`

**Interfaces:**
- Consumes: `AudioPlaybackCenter` (Task 2).
- Produces: `appState.audioPlaybackCenter: AudioPlaybackCenter` — consumed by Task 6/7's view wiring.

This is pure wiring (a `let` property, always instantiated — same shape as `trackScanCenter`/`targetExtractCenter`/`meetingRecorderCenter` just above it, none of which have a dedicated "identity" test since `let` already guarantees a single stored instance). No new test needed; `AudioPlaybackCenterTests` (Task 2) already covers the class's behavior.

- [ ] **Step 1: Add the property**

In `WatchtowerDesktop/Sources/App/AppState.swift`, immediately after the `meetingRecorderCenter` declaration:

```swift
    /// App-wide, single-slot registry for meeting recording + transcription, so
    /// an in-flight recording and its transcription survive navigating away from
    /// the calendar event that started it.
    let meetingRecorderCenter = MeetingRecorderCenter()

    /// App-wide, single-slot registry for meeting-recording audio playback, so
    /// only one recording's audio plays at a time regardless of how many
    /// transcript rows are expanded across the app.
    let audioPlaybackCenter = AudioPlaybackCenter()
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/swift-build.log; echo "EXIT: $?"`
Expected: EXIT: 0.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/App/AppState.swift
git commit -m "feat(transcriber): wire AudioPlaybackCenter into AppState"
```

---

### Task 4: `AudioPlayerControlView`

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Calendar/AudioPlayerControlView.swift`
- Create: `WatchtowerDesktop/Tests/AudioPlayerControlViewTests.swift`

**Interfaces:**
- Consumes: `AudioPlaybackCenter` (Task 2) — `activeTranscriptID`, `failedTranscriptID`, `errorMessage`, `isPlaying`, `currentTime`, `duration`, `play(url:transcriptID:)`, `pause()`, `resume()`, `seek(to:)`.
- Produces: `struct AudioPlayerControlView: View { let transcriptID: Int64; let audioURL: URL; let center: AudioPlaybackCenter }` — consumed by Task 5's `TranscriptAudioControl`.

Takes `center` as an explicit parameter (not `@Environment(AppState.self)`) so it is a self-contained, independently testable unit — this is a deliberate deviation from the design doc's `@Environment` sketch, made because it lets `ViewInspector` exercise the view directly without needing a real `AppState`/`DatabaseManager`.

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/AudioPlayerControlViewTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

private final class FakePlayback: AudioPlayback {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10
    private(set) var isPlaying = false

    @discardableResult
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

private struct BoomError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class AudioPlayerControlViewTests: XCTestCase {
    func testTapStartsPlaybackOnIdleRow() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            center: center
        )

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(center.activeTranscriptID, 1)
        XCTAssertTrue(center.isPlaying)
    }

    func testSecondTapPausesTheSameRow() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            center: center
        )

        try view.inspect().find(ViewType.Button.self).tap()
        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.activeTranscriptID, 1)
    }

    func testShowsErrorMessageWhenPlaybackFails() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in throw BoomError() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            center: center
        )

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertNoThrow(try view.inspect().find(text: "boom"))
    }

    func testNoErrorMessageShownBeforeAnyPlayAttempt() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            center: center
        )

        XCTAssertThrowsError(try view.inspect().find(text: "boom"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter AudioPlayerControlViewTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: build FAILS — `AudioPlayerControlView` does not exist yet.

- [ ] **Step 3: Implement `AudioPlayerControlView`**

Create `WatchtowerDesktop/Sources/Views/Calendar/AudioPlayerControlView.swift`:

```swift
import SwiftUI

/// Play/pause + scrubber control for a transcript's recorded audio. Takes the
/// shared `AudioPlaybackCenter` explicitly (not via `@Environment`) so it is a
/// self-contained, independently testable unit.
struct AudioPlayerControlView: View {
    let transcriptID: Int64
    let audioURL: URL
    let center: AudioPlaybackCenter

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var isActive: Bool { center.activeTranscriptID == transcriptID }
    private var hasFailed: Bool { center.failedTranscriptID == transcriptID }
    private var displayedDuration: TimeInterval { isActive ? center.duration : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isActive && center.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help(isActive && center.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : (isActive ? center.currentTime : 0) },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(displayedDuration, 0.01),
                    onEditingChanged: handleScrub
                )

                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if hasFailed, let message = center.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var timeLabel: String {
        let elapsed = isActive ? center.currentTime : 0
        return "\(formatSeconds(elapsed)) / \(formatSeconds(displayedDuration))"
    }

    private func togglePlay() {
        if isActive {
            if center.isPlaying {
                center.pause()
            } else {
                center.resume()
            }
        } else {
            center.play(url: audioURL, transcriptID: transcriptID)
        }
    }

    private func handleScrub(_ editing: Bool) {
        isScrubbing = editing
        guard !editing else { return }
        if !isActive {
            center.play(url: audioURL, transcriptID: transcriptID)
        }
        center.seek(to: scrubTime)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter AudioPlayerControlViewTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: all 4 tests PASS, EXIT: 0.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/AudioPlayerControlView.swift \
        WatchtowerDesktop/Tests/AudioPlayerControlViewTests.swift
git commit -m "feat(transcriber): add AudioPlayerControlView (play/pause + scrubber)"
```

---

### Task 5: `TranscriptAudioControl` wrapper

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/AudioPlayerControlView.swift` (append)
- Create: `WatchtowerDesktop/Tests/TranscriptAudioControlTests.swift`

**Interfaces:**
- Consumes: `AudioPlayerControlView` (Task 4), `MeetingTranscript` (existing model), `AudioPlaybackCenter` (Task 2).
- Produces: `struct TranscriptAudioControl: View { let transcript: MeetingTranscript; let center: AudioPlaybackCenter }` — consumed by Task 6 and Task 7.

Renders `AudioPlayerControlView` when `transcript.id` and `transcript.audioPath` are both present, or a "Recording deleted" caption when `audioPath == nil` (the retention sweep already ran — see `MeetingTranscript.swift`'s doc comment on `audioPath`). Shared by both call sites so this conditional isn't triplicated.

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/TranscriptAudioControlTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class TranscriptAudioControlTests: XCTestCase {
    private func makeTranscript(id: Int64? = 1, audioPath: String? = "/tmp/rec.caf") -> MeetingTranscript {
        MeetingTranscript(
            id: id,
            eventID: nil,
            title: "Test",
            audioPath: audioPath,
            durationSec: 20,
            langStats: "{}",
            transcriptText: "hello",
            summaryJSON: nil,
            createdAt: "2026-07-15T10:00:00Z",
            updatedAt: "2026-07-15T10:00:00Z"
        )
    }

    func testShowsPlayerWhenAudioPathPresent() throws {
        let view = TranscriptAudioControl(transcript: makeTranscript(), center: AudioPlaybackCenter())
        XCTAssertNoThrow(try view.inspect().find(ViewType.Button.self))
    }

    func testShowsDeletedCaptionWhenAudioPathNil() throws {
        let view = TranscriptAudioControl(transcript: makeTranscript(audioPath: nil), center: AudioPlaybackCenter())
        XCTAssertNoThrow(try view.inspect().find(text: "Recording deleted"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptAudioControlTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: build FAILS — `TranscriptAudioControl` does not exist yet.

- [ ] **Step 3: Implement `TranscriptAudioControl`**

Append to `WatchtowerDesktop/Sources/Views/Calendar/AudioPlayerControlView.swift`:

```swift

/// Audio control for a transcript row, or an explanatory caption when the
/// retention sweep already deleted the source file (`audioPath == nil`).
/// Shared by `TranscriptSectionView` (event-linked) and `CalendarEventsView`
/// (ad-hoc) so the conditional isn't duplicated at each call site.
struct TranscriptAudioControl: View {
    let transcript: MeetingTranscript
    let center: AudioPlaybackCenter

    var body: some View {
        if let id = transcript.id, let audioPath = transcript.audioPath {
            AudioPlayerControlView(
                transcriptID: id,
                audioURL: URL(fileURLWithPath: audioPath),
                center: center
            )
        } else if transcript.audioPath == nil {
            Text("Recording deleted")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter TranscriptAudioControlTests 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: both tests PASS, EXIT: 0.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/AudioPlayerControlView.swift \
        WatchtowerDesktop/Tests/TranscriptAudioControlTests.swift
git commit -m "feat(transcriber): add TranscriptAudioControl wrapper"
```

---

### Task 6: Wire playback into `TranscriptSectionView` (event-linked)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift`

**Interfaces:**
- Consumes: `TranscriptAudioControl` (Task 5), `appState.audioPlaybackCenter` (Task 3).

Adds the audio control to the already-existing `transcriptRow` `DisclosureGroup` (which already shows full transcript text — no change needed there), placed between the transcript text `ScrollView` and the "Retry recap"/"Re-transcribe" button row. No new test: this view already reads `@Environment(AppState.self)`, which is why it isn't `ViewInspector`-tested today (same as before this feature) — verified by hand in Task 8.

- [ ] **Step 1: Add the control**

In `WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift`, inside `transcriptRow`, replace:

```swift
                ScrollView {
                    Text(transcript.transcriptText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                HStack(spacing: 8) {
                    if !hasRecap {
```

with:

```swift
                ScrollView {
                    Text(transcript.transcriptText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                TranscriptAudioControl(transcript: transcript, center: appState.audioPlaybackCenter)

                HStack(spacing: 8) {
                    if !hasRecap {
```

- [ ] **Step 2: Build and run the full test suite**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/swift-build.log; echo "EXIT: $?"`
Expected: EXIT: 0.

Run: `cd WatchtowerDesktop && swift test 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: EXIT: 0, all tests still pass.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/TranscriptSectionView.swift
git commit -m "feat(transcriber): show audio playback control on event-linked recordings"
```

---

### Task 7: Convert `CalendarEventsView.adHocRow` into an expandable row (ad-hoc)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift`

**Interfaces:**
- Consumes: `TranscriptLangBadges`/`TranscriptFormatting` (Task 1), `TranscriptAudioControl` (Task 5), `appState.audioPlaybackCenter` (Task 3).

Converts `adHocRow` from a flat `HStack` into a `DisclosureGroup` matching `TranscriptSectionView.transcriptRow`'s shape: collapsed label shows title/date/duration (as today); expanded content adds lang badges, the full (untruncated) summary, the full `transcriptText` in a scrollable selectable text view, the audio control, and keeps the existing "Link to event…" button. No new test — same untestable-via-`ViewInspector` reasoning as Task 6 (this view also reads `@Environment(AppState.self)`); verified by hand in Task 8.

- [ ] **Step 1: Replace `adHocRow`**

In `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift`, replace the entire `adHocRow` function:

```swift
    private func adHocRow(_ transcript: MeetingTranscript) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(.callout)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                    Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let summary = transcript.parsedSummary?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                linkTarget = transcript
            } label: {
                Label("Link to event…", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
```

with:

```swift
    private func adHocRow(_ transcript: MeetingTranscript) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TranscriptLangBadges(langStatsJSON: transcript.langStats)

                if let summary = transcript.parsedSummary?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    Text(transcript.transcriptText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                TranscriptAudioControl(transcript: transcript, center: appState.audioPlaybackCenter)

                Button {
                    linkTarget = transcript
                } label: {
                    Label("Link to event…", systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(.callout)
                    .fontWeight(.medium)
                Text("\(TranscriptFormatting.formattedDate(transcript.createdAt)) · \(TranscriptFormatting.formatDuration(transcript.durationSec))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
```

- [ ] **Step 2: Build and run the full test suite**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/swift-build.log; echo "EXIT: $?"`
Expected: EXIT: 0.

Run: `cd WatchtowerDesktop && swift test 2>&1 | tee /tmp/swift-test.log; echo "EXIT: $?"`
Expected: EXIT: 0, all tests still pass.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift
git commit -m "feat(transcriber): expand ad-hoc recordings to show text + audio playback"
```

---

### Task 8: Manual verification in the running app

**Files:** none (no code changes — this task only runs and exercises the built app).

Per the project's "drive the feature, not only tests" rule (see the live-transcription design doc's own Testing section for precedent): build the dev app and confirm the feature works end-to-end, since audio playback and disclosure-group layout are not exercised by the unit/ViewInspector tests above.

- [ ] **Step 1: Build the dev app**

Run: `make app-dev`
Expected: build succeeds, app launches.

- [ ] **Step 2: Verify an ad-hoc recording**

In the Calendar tab, make a short ad-hoc recording (Record → speak a sentence → Stop) and wait for it to finish transcribing. In the "Recordings" section, click the row to expand it. Confirm:
- The full transcript text is visible and selectable.
- A play/pause button and scrubber appear.
- Clicking play starts audio; the elapsed-time label advances; dragging the scrubber seeks.
- Clicking pause stops audio without losing position; clicking play again resumes from there.

- [ ] **Step 3: Verify an event-linked recording**

Record against a real calendar event (Record from an event row → Stop). Open the event's detail view, expand the recording under "Recordings". Confirm the same text + playback behavior as Step 2, alongside the existing "Retry recap"/"Re-transcribe" buttons.

- [ ] **Step 4: Verify single-active-player behavior**

With two recordings available (the ad-hoc one from Step 2 and the event-linked one from Step 3), expand both, press play on the first, then press play on the second. Confirm the first stops (its button reverts to the play icon) and only the second is audibly playing.

- [ ] **Step 5: Verify the deleted-audio caption (if reachable)**

If a recording old enough to have had its audio swept by retention is available, expand it and confirm it shows "Recording deleted" instead of a broken/absent control. (If none exists, skip this step — it is already covered by `TranscriptAudioControlTests`.)

No commit for this task — it produces no diff.
