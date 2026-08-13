import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Canned `watchtower dictate clean --mode idea` stdout envelope — the REAL
/// idea shape (`title`+`body`, `cmd/dictate.go`), for the idea mode quick
/// capture actually dictates in.
private let ideaCleanedEnvelope = Data(#"{"mode":"idea","title":"Idea title","body":"cleaned"}"#.utf8)

// MARK: - QuickCaptureViewModel Tests
//
// Subclasses `MeetingRecorderTestCase` (not a meeting-recorder test itself)
// purely for `isolatedDefaults()`/`waitUntil()` — the same reuse
// `DictationCenterTests` makes, needed here for the M1 regression test below,
// which drives a real `DictationCenter` against the shared fakes.
@MainActor
final class QuickCaptureViewModelTests: MeetingRecorderTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - save()

    func testSaveHappyPathInsertsIdeaAndMention() throws {
        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: "Ship a weekly digest", text: "we should ship a weekly digest email")

        vm.save(dbPool: dbManager.dbPool)

        let ideaID = try XCTUnwrap(vm.savedIdeaID)
        XCTAssertNil(vm.error)
        let idea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.title, "Ship a weekly digest")
        XCTAssertEqual(idea?.essence, "we should ship a weekly digest email")
        XCTAssertEqual(idea?.statusRaw, "active")
        XCTAssertEqual(idea?.source, "owner")

        let mentions = try dbManager.dbPool.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }
        XCTAssertEqual(mentions.map(\.quote), ["we should ship a weekly digest email"])
    }

    func testSaveWithEmptyResultInsertsNothingAndSetsError() throws {
        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: nil, text: "")

        vm.save(dbPool: dbManager.dbPool)

        XCTAssertNil(vm.savedIdeaID)
        XCTAssertNotNil(vm.error)
        let ideas = try dbManager.dbPool.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 10) }
        XCTAssertTrue(ideas.isEmpty)
    }

    func testSaveWithNoResultYetSetsErrorWithoutInserting() throws {
        let vm = QuickCaptureViewModel()

        vm.save(dbPool: dbManager.dbPool)

        XCTAssertNil(vm.savedIdeaID)
        XCTAssertNotNil(vm.error)
        let ideas = try dbManager.dbPool.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 10) }
        XCTAssertTrue(ideas.isEmpty)
    }

    func testSaveFallsBackToTextPrefixWhenCleanupReturnedNoTitle() throws {
        let vm = QuickCaptureViewModel()
        let longText = String(repeating: "a", count: 120)
        vm.result = DictationCleanResult(title: nil, text: longText)

        vm.save(dbPool: dbManager.dbPool)

        let ideaID = try XCTUnwrap(vm.savedIdeaID)
        let idea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.title, String(longText.prefix(80)))
        XCTAssertEqual(idea?.essence, longText)
    }

    // MARK: - saveRaw() (M2 fix round: the failed-state "never lose the speech" fallback)

    func testSaveRawInsertsLastRawWithPrefixTitle() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: Data(), error: StubCleanupError())
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["said something before it failed"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        let vm = QuickCaptureViewModel()
        vm.start(center: center)
        await waitUntil("recording") { center.phase == .recording }
        recorder.emit([Float](repeating: 0.1, count: 1_600))
        vm.stop()
        await waitUntil("failed") {
            if case .failed = center.phase { return true }
            return false
        }

        vm.saveRaw(dbPool: dbManager.dbPool)

        let ideaID = try XCTUnwrap(vm.savedIdeaID)
        let idea = try await dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.essence, "said something before it failed")
        XCTAssertEqual(idea?.title, String("said something before it failed".prefix(80)))
    }

    func testSaveRawWithNothingCapturedSetsErrorWithoutInserting() throws {
        let vm = QuickCaptureViewModel()

        vm.saveRaw(dbPool: dbManager.dbPool)

        XCTAssertNil(vm.savedIdeaID)
        XCTAssertNotNil(vm.error)
    }

    // MARK: - M1 fix-round regression: ownership gate on stop()/cancel()

    /// Closing the quick-capture window while ANOTHER surface (a different
    /// `DictationButton`, in practice) is dictating must never kill that
    /// dictation. `QuickCaptureViewModel.start` loses the race to
    /// `DictationCenter`'s single-slot exclusivity — `ownsCapture` must
    /// reflect that, and `stop()`/`cancel()` must both no-op rather than
    /// reaching into a capture this VM does not own.
    func testCancelDoesNotTouchAnotherActiveDictation() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("en", forKey: "transcription.forceLang")
        let recorder = FakeMicRecorder()
        let runner = FakeCLIRunner(stdout: ideaCleanedEnvelope)
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["other field's speech"]), supportsLive: true) },
            runnerResolver: { runner },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        var otherResult: DictationCleanResult?
        center.start(targetID: "other-field", mode: .idea, onLiveText: { _ in }, onResult: { otherResult = $0 })
        await waitUntil("other dictation recording") { center.phase == .recording }

        let vm = QuickCaptureViewModel()
        vm.start(center: center)

        XCTAssertFalse(vm.ownsCapture, "quick capture must not have won an already-held shared slot")
        XCTAssertEqual(center.activeTargetID, "other-field")
        XCTAssertEqual(vm.state, .unavailable)

        vm.cancel() // the window-close path — must be a no-op here
        vm.stop()   // belt-and-braces: neither control may reach the other capture

        XCTAssertEqual(center.activeTargetID, "other-field", "the other dictation's ownership must be untouched")
        XCTAssertEqual(center.phase, .recording, "cancel()/stop() from a non-owning quick capture must not touch it")

        recorder.emit([Float](repeating: 0.1, count: 1_600))
        center.stop()
        await waitUntil("other result delivered") { otherResult != nil }

        XCTAssertEqual(otherResult, DictationCleanResult(title: "Idea title", text: "cleaned"),
                       "the other dictation must still complete normally")
    }

    /// The owning case, as a control: quick capture's own cancel() DOES stop
    /// its own capture, so the gate above isn't just permanently disabling
    /// the controls.
    func testCancelStopsOwnCapture() async throws {
        let defaults = try isolatedDefaults()
        let recorder = FakeMicRecorder()
        let center = DictationCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { FakeCLIRunner() },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        let vm = QuickCaptureViewModel()
        vm.start(center: center)
        await waitUntil("recording") { center.phase == .recording }
        XCTAssertTrue(vm.ownsCapture)

        vm.cancel()

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.activeTargetID)
    }

    // MARK: - m5 (final review): scene reuse must not show a stale outcome

    /// A reopened Quick Capture window reuses the scene (and can reuse the
    /// VM): `start()` must clear the previous run's outcome, or a stale
    /// "Saved ✓" renders over a hot mic.
    func testStartResetsStaleOutcomeFromAPreviousRun() async throws {
        let defaults = try isolatedDefaults()
        let center = DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
            runnerResolver: { FakeCLIRunner() },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )

        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: nil, text: "stale")
        vm.savedIdeaID = 7
        vm.error = "stale error"
        vm.liveText = "stale live"

        vm.start(center: center)

        XCTAssertNil(vm.result)
        XCTAssertNil(vm.savedIdeaID)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.liveText, "")
        XCTAssertEqual(vm.state, .loading, "a fresh start must render the capture, not the previous outcome")

        vm.cancel()
    }

    // MARK: - QuickCaptureState.derive() (M2 fix round: pure state derivation)

    func testDeriveStateSavedWinsOverEverythingElse() {
        let state = QuickCaptureState.derive(
            ownsCapture: false, phase: .idle, lastRaw: nil,
            result: DictationCleanResult(title: nil, text: "ignored"), savedIdeaID: 42
        )
        XCTAssertEqual(state, .saved(42))
    }

    func testDeriveStateResultReadyWinsEvenAfterOwnershipIsGone() {
        // Once onResult fires, DictationCenter has already reset
        // activeTargetID/phase to idle — the result must still render.
        let result = DictationCleanResult(title: "T", text: "hi")
        let state = QuickCaptureState.derive(ownsCapture: false, phase: .idle, lastRaw: nil, result: result, savedIdeaID: nil)
        XCTAssertEqual(state, .resultReady(result))
    }

    func testDeriveStateUnavailableWhenNotOwning() {
        let state = QuickCaptureState.derive(ownsCapture: false, phase: .recording, lastRaw: nil, result: nil, savedIdeaID: nil)
        XCTAssertEqual(state, .unavailable)
    }

    func testDeriveStateRecordingWhileOwningAndPhaseRecording() {
        let state = QuickCaptureState.derive(ownsCapture: true, phase: .recording, lastRaw: nil, result: nil, savedIdeaID: nil)
        XCTAssertEqual(state, .recording)
    }

    func testDeriveStateLoadingWhileEngineLoads() {
        let state = QuickCaptureState.derive(ownsCapture: true, phase: .loadingEngine, lastRaw: nil, result: nil, savedIdeaID: nil)
        XCTAssertEqual(state, .loading)
    }

    func testDeriveStateCleaningWhilePhaseCleaning() {
        let state = QuickCaptureState.derive(ownsCapture: true, phase: .cleaning, lastRaw: nil, result: nil, savedIdeaID: nil)
        XCTAssertEqual(state, .cleaning)
    }

    /// The M2 bug this fixes: a failed dictation used to render as an
    /// eternal "Listening…" because the view never read `center.phase` at
    /// all. `.failed` must carry both the message AND whatever `lastRaw`
    /// there is, so the failed state can offer to save it.
    func testDeriveStateFailedCarriesMessageAndRaw() {
        let state = QuickCaptureState.derive(
            ownsCapture: true, phase: .failed("cleanup failed — raw text kept"),
            lastRaw: "said something", result: nil, savedIdeaID: nil
        )
        XCTAssertEqual(state, .failed(message: "cleanup failed — raw text kept", raw: "said something"))
    }

    func testDeriveStateFailedWithNoRawWhenNothingWasTranscribed() {
        let state = QuickCaptureState.derive(
            ownsCapture: true, phase: .failed("microphone failed to start"),
            lastRaw: nil, result: nil, savedIdeaID: nil
        )
        XCTAssertEqual(state, .failed(message: "microphone failed to start", raw: nil))
    }
}

/// `stop()`/cancel-path cleanup failing to reach the CLI — distinct from a
/// generic error so a test failure message can't be confused with a real
/// `CLIRunnerError` (the `DictationCenterTests` precedent).
private struct StubCleanupError: Error {}
