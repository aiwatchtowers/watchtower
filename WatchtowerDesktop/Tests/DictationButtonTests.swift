import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

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

    private func makeCenter() throws -> DictationCenter {
        DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { nil },
            defaults: try XCTUnwrap(UserDefaults(suiteName: "DictationButtonViewTests-\(UUID().uuidString)")),
            engineIdleTTL: .seconds(900)
        )
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
}
