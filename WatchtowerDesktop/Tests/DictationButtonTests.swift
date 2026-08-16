import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

/// An engine load failing in the button rendering tests — local so a failure
/// message can't be confused with the center tests' stubs.
private struct ButtonStubError: Error {}

/// `DictationSpan` is the pure span-management core of `DictationButton`,
/// extracted so these tests don't need ViewInspector.
final class DictationSpanTests: XCTestCase {

    // MARK: - base

    func test_baseEmptyField_returnsExistingForIdeaAndChat() {
        XCTAssertEqual(DictationSpan.base(existing: "", mode: .idea), "")
        XCTAssertEqual(DictationSpan.base(existing: "", mode: .chat), "")
    }

    func test_baseNonEmptyNote_endsWithDoubleNewline() {
        XCTAssertEqual(DictationSpan.base(existing: "Existing notes", mode: .note),
                       "Existing notes\n\n")
    }

    func test_baseNonEmptyChat_endsWithSingleSpace() {
        let base = DictationSpan.base(existing: "hello", mode: .chat)
        XCTAssertEqual(base, "hello ")
        XCTAssertFalse(base.hasSuffix("  "))
    }

    // MARK: - compose

    func test_composeAppendsDictatedVerbatim() {
        // No trimming of the dictated chunk — leading/trailing whitespace in
        // what the engine returned is kept exactly as delivered.
        XCTAssertEqual(DictationSpan.compose(base: "hello ", dictated: "  world  "),
                       "hello   world  ")
    }

    func test_composeEmptyDictated_returnsOriginalExistingText() {
        let noteBase = DictationSpan.base(existing: "hello", mode: .note)
        XCTAssertEqual(DictationSpan.compose(base: noteBase, dictated: ""), "hello")

        let chatBase = DictationSpan.base(existing: "hello", mode: .chat)
        XCTAssertEqual(DictationSpan.compose(base: chatBase, dictated: ""), "hello")
    }
}

/// Capsule rendering of `DictationButton` — driven by a real `DictationCenter`
/// on fakes (the `DictationCenterTests` doubles), inspected via ViewInspector
/// through the explicit `center:` parameter (ViewInspector cannot inject
/// custom `@Environment` values — the `ChatInputViewTests` precedent).
@MainActor
final class DictationButtonViewTests: XCTestCase {

    private func makeCenter(
        engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber
            = { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) }
    ) throws -> DictationCenter {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DictationButtonViewTests-\(UUID().uuidString)"))
        // Pin the whisper lane (absent key → Apple on macOS 26) so these
        // suites stay on the injectable engineFactory path.
        defaults.set("small", forKey: DictationEngineChoice.defaultsKey)
        return DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: engineFactory,
            runnerResolver: { nil },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
    }

    /// The `MeetingRecorderTestCase.waitUntil` shape, local — this class
    /// extends plain `XCTestCase`.
    private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
        }
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func makeButton(targetID: String = "t", center: DictationCenter) -> DictationButton {
        DictationButton(text: .constant(""), mode: .chat, targetID: targetID, center: center)
    }

    private func hasControl(_ sut: DictationButton, _ identifier: String) -> Bool {
        (try? sut.inspect().find(viewWithAccessibilityIdentifier: identifier)) != nil
    }

    // MARK: - Timer label

    func testTimerLabelFormats() {
        XCTAssertEqual(DictationButton.timerLabel(.zero), "0:00")
        XCTAssertEqual(DictationButton.timerLabel(.seconds(5)), "0:05")
        XCTAssertEqual(DictationButton.timerLabel(.seconds(62)), "1:02")
        // Hours fold into minutes — no h:mm:ss form.
        XCTAssertEqual(DictationButton.timerLabel(.seconds(3661)), "61:01")
        // Defensive clamp: a negative duration renders as zero, never "-1:-05".
        XCTAssertEqual(DictationButton.timerLabel(.seconds(-5)), "0:00")
    }

    // MARK: - Capsule controls by phase

    func testRecordingShowsPauseAndStopButtons() throws {
        let center = try makeCenter()
        defer { center.cancel() }
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        XCTAssertEqual(center.phase, .recording)

        let sut = makeButton(center: center)
        XCTAssertTrue(hasControl(sut, "dictation.pause"), "recording capsule must offer pause")
        XCTAssertTrue(hasControl(sut, "dictation.stop"), "recording capsule must offer stop")
        XCTAssertFalse(hasControl(sut, "dictation.resume"), "no resume while recording")
    }

    func testPausedShowsResumeAndStop() throws {
        let center = try makeCenter()
        defer { center.cancel() }
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        center.pause()
        XCTAssertEqual(center.phase, .paused)

        let sut = makeButton(center: center)
        XCTAssertTrue(hasControl(sut, "dictation.resume"), "paused capsule must offer resume")
        XCTAssertTrue(hasControl(sut, "dictation.stop"), "paused capsule must offer stop")
        XCTAssertFalse(hasControl(sut, "dictation.pause"), "no pause while paused")
    }

    // MARK: - Esc = cancel

    func testEscCancelsOwnedDictation() throws {
        let center = try makeCenter()
        var resultFired = 0
        center.start(targetID: "t", mode: .chat,
                     onLiveText: { _ in }, onResult: { _ in resultFired += 1 })
        XCTAssertEqual(center.phase, .recording)

        let sut = makeButton(center: center)
        try sut.inspect().find(ViewType.HStack.self).callOnExitCommand()

        XCTAssertEqual(center.phase, .idle, "Esc discards — cancel, not stop")
        XCTAssertNil(center.activeTargetID)
        XCTAssertEqual(resultFired, 0, "a cancelled dictation must never deliver a result")
    }

    func testEscOnForeignTargetDoesNotCancel() throws {
        let center = try makeCenter()
        defer { center.cancel() }
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { _ in })

        let sut = makeButton(targetID: "other", center: center)
        try sut.inspect().find(ViewType.HStack.self).callOnExitCommand()

        XCTAssertEqual(center.phase, .recording,
                       "Esc on a button that doesn't own the dictation must not cancel it")
    }

    // MARK: - Rendering by phase (stopping / cleaning / failed / loading badge)

    func testStoppingShowsTranscribingLabel() async throws {
        let gate = AsyncGate()
        let center = try makeCenter { _ in
            await gate.wait()
            return TestTranscriber(ScriptedEngine(texts: []), supportsLive: true)
        }
        defer {
            gate.release()
            center.cancel()
        }
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        center.stop() // during the (gated) engine load — `.stopping` holds
        XCTAssertEqual(center.phase, .stopping)

        let sut = makeButton(center: center)
        XCTAssertNoThrow(try sut.inspect().find(text: "Transcribing…"),
                         "the stopping capsule must show the transcribing label")
    }

    func testCleaningShowsCleaningLabel() async throws {
        let recorder = FakeMicRecorder()
        let gate = AsyncGate()
        let runner = GatedCLIRunner(gate: gate, stdout: Data(#"{"mode":"chat","text":"cleaned"}"#.utf8))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DictationButtonViewTests-\(UUID().uuidString)"))
        defaults.set("en", forKey: "transcription.forceLang")
        defaults.set("small", forKey: DictationEngineChoice.defaultsKey) // pin the whisper lane
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        var result: DictationCleanResult?
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
        await waitUntil("engine loaded") { center.phase == .recording && !center.isEngineLoading }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("cleaning") { center.phase == .cleaning }

        let sut = makeButton(center: center)
        XCTAssertNoThrow(try sut.inspect().find(text: "Cleaning…"),
                         "the cleaning capsule must show the cleaning label")

        gate.release()
        await waitUntil("result delivered") { result != nil }
    }

    func testFailedShowsRetryAffordance() async throws {
        let center = try makeCenter { _ in throw ButtonStubError() }
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        let sut = makeButton(center: center)
        XCTAssertTrue(hasControl(sut, "dictation.retry"), "the failed state must offer retry")
        center.retry()
    }

    func testLoadingBadgeVisibleWhileEngineLoadsAndGoneAfter() async throws {
        let gate = AsyncGate()
        let center = try makeCenter { _ in
            await gate.wait()
            return TestTranscriber(ScriptedEngine(texts: []), supportsLive: true)
        }
        defer { center.cancel() }
        center.start(targetID: "t", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        XCTAssertTrue(center.isEngineLoading)

        let sut = makeButton(center: center)
        XCTAssertNoThrow(try sut.inspect().find(text: "Loading model…"),
                         "the badge must ride the recording capsule while the engine loads")

        gate.release()
        await waitUntil("engine loaded") { !center.isEngineLoading }

        XCTAssertThrowsError(try sut.inspect().find(text: "Loading model…"),
                             "the badge must disappear once the engine is loaded")
    }
}
