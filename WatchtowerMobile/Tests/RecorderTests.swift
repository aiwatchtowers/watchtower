import AVFoundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone recorder (spec §13 C2): too-short captures, the 3 h cap,
/// interruptions, pauses, marks and the event link. Every test runs over
/// a fake audio engine and a hand-moved clock: no audio is ever recorded.
@MainActor
final class RecorderTests: XCTestCase {
    private func meeting(start: Date) -> MeetingEvent {
        MeetingEvent(id: "evt-1", title: "Design sync", start: start, end: start.addingTimeInterval(45 * 60))
    }

    // MARK: - Too short

    func testZeroSecondRecordingIsTooShortAndNeverUploaded() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        XCTAssertEqual(rig.controller.phase, .recording)

        await rig.controller.stop()

        XCTAssertEqual(rig.controller.phase, .tooShort)
        XCTAssertEqual(rig.controller.statusLine, "Too short to save")
        XCTAssertTrue(try rig.store.phoneRecordings().isEmpty)
        let uploads = try await relayUploads(in: rig.transport)
        XCTAssertTrue(uploads.isEmpty, "a 0-second recording is never uploaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(rig.engine.begunURLs.first).path))
    }

    // MARK: - Length cap

    func testAutoStopsAtThreeHoursWithANoticeFiveMinutesBefore() async throws {
        let rig = try makeRecorderRig()
        var notices = 0
        rig.controller.onCapNotice = { notices += 1 }
        await rig.controller.recordVoiceNote()

        rig.clock.advance(2 * 3_600 + 55 * 60 - 1)
        await rig.controller.tick()
        XCTAssertNil(rig.controller.capNotice)

        rig.clock.advance(1)
        await rig.controller.tick()
        XCTAssertEqual(rig.controller.capNotice, "Recording stops in 5 minutes (3-hour limit).")
        XCTAssertEqual(notices, 1)

        rig.clock.advance(299)
        await rig.controller.tick()
        XCTAssertEqual(rig.controller.phase, .recording)
        XCTAssertEqual(notices, 1, "the notice is raised once")

        rig.clock.advance(1)
        await rig.controller.tick()
        guard case let .saved(saved) = rig.controller.phase else {
            return XCTFail("auto-stop at 3 h exactly, got \(rig.controller.phase)")
        }
        XCTAssertEqual(saved.durationSec, 3 * 3_600)
        XCTAssertEqual(rig.engine.finishCount, 1)
        let uploads = try await relayUploads(in: rig.transport)
        XCTAssertEqual(uploads.map(\.durationSec), [3 * 3_600])
    }

    func testALateTickStillSavesExactlyThreeHours() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.clock.advance(3 * 3_600 + 40)
        await rig.controller.tick()
        guard case let .saved(saved) = rig.controller.phase else {
            return XCTFail("expected an auto-stop, got \(rig.controller.phase)")
        }
        XCTAssertEqual(saved.durationSec, 3 * 3_600, "the cap clamps a tick that came late")
    }

    // MARK: - Review focus 1: interruptions

    func testInterruptionPausesAndResumesIntoOneFileExcludingTheGap() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.clock.advance(60)
        await rig.controller.tick()

        postInterruption(rig.notifications, began: true)
        XCTAssertEqual(rig.controller.phase, .paused(.interruption))
        XCTAssertEqual(rig.controller.statusLine, "Paused — call in progress")

        rig.clock.advance(120)
        await rig.controller.tick()
        XCTAssertEqual(rig.controller.elapsed, 60, accuracy: 0.001, "the call does not count")
        XCTAssertEqual(rig.controller.timerText, "01:00")

        postInterruption(rig.notifications, began: false)
        XCTAssertEqual(rig.controller.phase, .recording)
        rig.clock.advance(30)
        await rig.controller.stop()

        XCTAssertEqual(rig.engine.begunURLs.count, 1, "one file for the whole recording")
        XCTAssertEqual(rig.engine.resumeCount, 1)
        XCTAssertEqual(rig.engine.finishCount, 1, "finalised once")
        let rows = try rig.store.phoneRecordings()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.durationSec, 90)
        XCTAssertEqual(rows.first?.fileURL(in: rig.directory), rig.engine.begunURLs.first)
    }

    func testAnInterruptionEndingWithoutResumeWaitsForTheOwner() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        postInterruption(rig.notifications, began: true)
        postInterruption(rig.notifications, began: false, shouldResume: false)
        XCTAssertEqual(rig.controller.phase, .paused(.user))
        XCTAssertEqual(rig.controller.statusLine, "Paused")
        XCTAssertEqual(rig.engine.resumeCount, 0)
    }

    func testAnInterruptionDuringAnOwnerPauseNeverResumes() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.controller.pause()
        postInterruption(rig.notifications, began: true)
        postInterruption(rig.notifications, began: false)
        XCTAssertEqual(rig.controller.phase, .paused(.user))
        XCTAssertEqual(rig.engine.resumeCount, 0)
    }

    // MARK: - Pause and marks

    func testMarksAreSecondOffsetsOfRecordedAudioAndStayLocal() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        XCTAssertEqual(rig.controller.statusLine, "Keeps going with the screen locked. 0 moments marked.")

        rig.clock.advance(12.7)
        rig.controller.markMoment()
        rig.controller.pause()
        XCTAssertEqual(rig.controller.statusLine, "Paused")
        rig.clock.advance(100)
        rig.controller.resume()
        rig.clock.advance(5)
        rig.controller.markMoment()
        XCTAssertEqual(rig.controller.statusLine, "Keeps going with the screen locked. 2 moments marked.")
        rig.clock.advance(3)
        await rig.controller.stop()

        let row = try XCTUnwrap(try rig.store.phoneRecordings().first)
        XCTAssertEqual(row.durationSec, 21, "the paused 100 s are not audio")
        XCTAssertEqual(try rig.store.phoneRecordingMarks(id: row.id), [12, 17])

        let batch = try await rig.transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(batch.changed.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        XCTAssertFalse(object.keys.contains { $0.contains("mark") }, "marks never travel: \(object.keys)")
    }

    func testOneMarkReadsSingular() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.controller.markMoment()
        XCTAssertEqual(rig.controller.statusLine, "Keeps going with the screen locked. 1 moment marked.")
    }

    // MARK: - Event link

    func testRecordThisMeetingSetsTheEventID() async throws {
        let rig = try makeRecorderRig()
        let event = meeting(start: rig.clock.now)
        await rig.controller.recordMeeting(event)
        XCTAssertEqual(rig.controller.context, .meeting(event))
        XCTAssertEqual(rig.controller.contextLabel, "Design sync · \(MeetingEvent.timeRange(event.start, event.end))")
        XCTAssertEqual(rig.controller.contextOptions, ["Design sync", "No meeting"])

        rig.clock.advance(30)
        await rig.controller.stop()

        let row = try XCTUnwrap(try rig.store.phoneRecordings().first)
        XCTAssertEqual(row.eventID, "evt-1")
        XCTAssertEqual(row.titleHint, "Design sync")
        let uploads = try await relayUploads(in: rig.transport)
        XCTAssertEqual(uploads.map(\.eventID), ["evt-1"])
    }

    func testNoMeetingLeavesTheEventIDAbsent() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordMeeting(meeting(start: rig.clock.now))
        rig.controller.selectMeeting(false)
        XCTAssertEqual(rig.controller.context, .voiceNote)
        XCTAssertEqual(rig.controller.contextLabel, "Voice note · not tied to an event")
        rig.clock.advance(30)
        await rig.controller.stop()

        let batch = try await rig.transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(batch.changed.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        XCTAssertNil(object["event_id"], "No meeting leaves event_id absent")
        XCTAssertNil(try rig.store.phoneRecordings().first?.eventID)
    }

    func testAFreeVoiceNoteOffersNoMeeting() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        XCTAssertEqual(rig.controller.context, .voiceNote)
        XCTAssertTrue(rig.controller.contextOptions.isEmpty, "no event to switch to")
        rig.clock.advance(30)
        await rig.controller.stop()
        XCTAssertNil(try rig.store.phoneRecordings().first?.eventID)
    }

    func testASecondEntryWhileRecordingKeepsTheCurrentRecording() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.controller.minimize()
        XCTAssertFalse(rig.controller.isPresented)
        await rig.controller.recordMeeting(meeting(start: rig.clock.now))
        XCTAssertTrue(rig.controller.isPresented)
        XCTAssertEqual(rig.controller.context, .voiceNote)
        XCTAssertEqual(rig.engine.begunURLs.count, 1)
    }

    // MARK: - Permission

    func testDeniedMicrophoneNeverStarts() async throws {
        let rig = try makeRecorderRig()
        rig.engine.permissionGranted = false
        await rig.controller.recordVoiceNote()
        XCTAssertEqual(rig.controller.phase, .denied)
        XCTAssertTrue(rig.engine.begunURLs.isEmpty)
    }

    // MARK: - A capture cut short (kill, jetsam, crash)

    func testBeginWritesTheLedgerRowBeforeAnyAudio() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordMeeting(meeting(start: rig.clock.now))
        let row = try XCTUnwrap(try rig.store.phoneRecordings().first)
        XCTAssertEqual(row.state, .recording)
        XCTAssertEqual(row.fileURL(in: rig.directory), rig.engine.begunURLs.first)
        XCTAssertEqual(row.eventID, "evt-1")
        rig.clock.advance(5)
        rig.controller.markMoment()
        try await poll { (try? rig.store.phoneRecordingMarks(id: row.id)) == [5] }
    }

    func testRelaunchFinalizesACaptureCutShortWithTheFilesDuration() async throws {
        let killed = try makeRecorderRig()
        await killed.controller.recordVoiceNote()
        killed.clock.advance(30)
        killed.controller.markMoment()
        let rowID = try XCTUnwrap(try killed.store.phoneRecordings().first?.id)
        try await poll { (try? killed.store.phoneRecordingMarks(id: rowID)) == [30] }
        // The process dies here: no stop(), no finish().

        let relaunched = try makeRecorderRig(sharing: killed)
        relaunched.engine.fileDuration = 42
        await relaunched.controller.recoverOnLaunch()
        await relaunched.controller.uploadPending()

        let row = try XCTUnwrap(try relaunched.store.phoneRecording(id: rowID))
        XCTAssertEqual(row.state, .uploading)
        XCTAssertEqual(row.durationSec, 42, "the duration is read from the file")
        XCTAssertEqual(try relaunched.store.phoneRecordingMarks(id: rowID), [30])
        let uploads = try await relayUploads(in: relaunched.transport)
        XCTAssertEqual(uploads.map(\.id), [rowID])
    }

    func testRelaunchDeletesARecordingFileWithNoRow() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.clock.advance(30)
        await rig.controller.stop()
        let kept = try XCTUnwrap(rig.engine.begunURLs.first)
        let orphan = rig.directory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data(repeating: 1, count: 32).write(to: orphan)

        let relaunched = try makeRecorderRig(sharing: rig)
        await relaunched.controller.recoverOnLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "a file with a row is kept")
    }

    func testRelaunchWithTheFileGoneFailsWithoutRetry() async throws {
        let killed = try makeRecorderRig()
        await killed.controller.recordVoiceNote()
        try FileManager.default.removeItem(at: try XCTUnwrap(killed.engine.begunURLs.first))

        let relaunched = try makeRecorderRig(sharing: killed)
        relaunched.engine.fileDuration = 42
        await relaunched.controller.recoverOnLaunch()

        let row = try XCTUnwrap(try relaunched.store.phoneRecordings().first)
        XCTAssertEqual(row.state, .failed)
        let stage = PhoneUploadStage(recording: row, heartbeat: nil, now: Date())
        XCTAssertEqual(stage, .failed(RecordingUploader.missingFileMessage, retryable: false))
        XCTAssertFalse(stage.offersRetry)
    }

    // MARK: - Engine failure, honest duration, saving

    func testAnEngineFailureStopsTheTimerAndSavesWhatWasWritten() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.clock.advance(50)
        rig.engine.fail("Audio services restarted, so the recording stopped here.")
        rig.clock.advance(600)
        try await poll { rig.controller.savedRecording != nil }
        XCTAssertEqual(rig.controller.savedRecording?.durationSec, 50, "the timer stopped at the failure")
        XCTAssertEqual(rig.controller.endNotice, "Audio services restarted, so the recording stopped here.")
        XCTAssertEqual(rig.engine.finishCount, 1)
    }

    func testTheSavedDurationNeverExceedsWhatTheFileHolds() async throws {
        let rig = try makeRecorderRig()
        rig.engine.fileDuration = 40
        await rig.controller.recordVoiceNote()
        rig.clock.advance(60)
        await rig.controller.stop()
        XCTAssertEqual(rig.controller.savedRecording?.durationSec, 40)
    }

    func testControlsAreOffWhileSaving() async throws {
        let rig = try makeRecorderRig()
        rig.engine.holdFinish = true
        await rig.controller.recordVoiceNote()
        rig.clock.advance(20)
        rig.controller.markMoment()
        let stopping = Task { await rig.controller.stop() }
        try await poll { rig.controller.phase == .saving }

        XCTAssertFalse(rig.controller.isCapturing, "the view disables every control off a capture")
        rig.controller.markMoment()
        rig.controller.pause()
        XCTAssertEqual(rig.controller.marks, [20], "no mark is taken, or dropped, while saving")
        XCTAssertEqual(rig.engine.pauseCount, 0)
        rig.controller.close()
        XCTAssertTrue(rig.controller.isPresented, "the recorder cannot be closed mid-save")

        rig.engine.releaseFinish()
        await stopping.value
        let row = try XCTUnwrap(try rig.store.phoneRecordings().first)
        XCTAssertEqual(try rig.store.phoneRecordingMarks(id: row.id), [20])
    }

    // MARK: - Ticker

    func testTheTickerSlowsToOnceASecondInTheBackground() throws {
        let rig = try makeRecorderRig(tickInterval: .milliseconds(100))
        XCTAssertEqual(rig.controller.currentTickInterval, .milliseconds(100))
        rig.controller.setForeground(false)
        XCTAssertEqual(rig.controller.currentTickInterval, .seconds(1))
        rig.controller.setForeground(true)
        XCTAssertEqual(rig.controller.currentTickInterval, .milliseconds(100))
    }

    // MARK: - Round 2: moved container, live capture, microphone change

    /// iOS moves the app's container (an app update): the recordings folder
    /// has a new absolute base. Nothing is deleted; recovery and the upload
    /// still find every file.
    func testAMovedContainerKeepsEveryRecording() async throws {
        let first = try makeRecorderRig()
        await first.controller.recordVoiceNote()
        first.clock.advance(30)
        await first.controller.stop()
        let saved = try XCTUnwrap(first.controller.savedRecording)
        await first.controller.recordVoiceNote()
        first.clock.advance(20)
        let strandedID = try XCTUnwrap(try first.store.phoneRecordings().first { $0.state == .recording }?.id)
        // The process dies here; the next one runs in a moved container.

        let container = FileManager.default.temporaryDirectory.appendingPathComponent("container-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let moved = container.appendingPathComponent(first.directory.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: first.directory, to: moved)

        let relaunched = try makeRecorderRig(sharing: first, directory: moved)
        relaunched.engine.fileDuration = 20
        await relaunched.controller.recoverOnLaunch()
        await relaunched.controller.uploadPending()

        let files = try FileManager.default.contentsOfDirectory(atPath: moved.path)
        XCTAssertEqual(files.count, 2, "nothing is swept: \(files)")
        XCTAssertEqual(try relaunched.store.phoneRecording(id: strandedID)?.state, .uploading)
        XCTAssertEqual(try relaunched.store.phoneRecording(id: saved.id)?.state, .uploading)
        let batch = try await relaunched.transport.changes(in: .relay, since: nil)
        let assets = batch.changed.compactMap(\.assetFileURL)
        XCTAssertEqual(assets.count, 2)
        XCTAssertTrue(assets.allSatisfy { $0.path.hasPrefix(moved.path) && FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Record is tapped while launch recovery runs: the new capture is never
    /// claimed, even though its file holds no readable audio yet.
    func testRecordTappedDuringLaunchRecoveryKeepsTheNewCapture() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        let liveID = try XCTUnwrap(try rig.store.phoneRecordings().first?.id)
        rig.engine.fileDuration = nil

        await rig.controller.recoverOnLaunch()

        XCTAssertEqual(try rig.store.phoneRecording(id: liveID)?.state, .recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(rig.engine.begunURLs.first).path))
        rig.engine.fileDuration = FakeAudioEngine.unclamped
        rig.clock.advance(30)
        await rig.controller.stop()
        XCTAssertEqual(rig.controller.savedRecording?.durationSec, 30)
    }

    func testAMicrophoneChangeStopsAndSavesWithANotice() async throws {
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.clock.advance(45)
        rig.engine.fail(CaptureEndWatch.microphoneChangedMessage)
        rig.clock.advance(300)
        try await poll { rig.controller.savedRecording != nil }
        XCTAssertEqual(rig.controller.savedRecording?.durationSec, 45, "the timer never runs over a silent tap")
        XCTAssertEqual(rig.controller.endNotice, "Recording stopped: the microphone changed.")
    }

    /// A resume the microphone cannot continue (it changed while paused)
    /// ends the capture and saves it, instead of leaving it paused forever.
    func testAResumeTheMicrophoneCannotContinueSavesTheCapture() async throws {
        struct MicrophoneChanged: LocalizedError {
            var errorDescription: String? { CaptureEndWatch.microphoneChangedMessage }
        }
        let rig = try makeRecorderRig()
        await rig.controller.recordVoiceNote()
        rig.clock.advance(25)
        rig.controller.pause()
        rig.engine.resumeError = MicrophoneChanged()
        rig.controller.resume()
        try await poll { rig.controller.savedRecording != nil }
        XCTAssertEqual(rig.controller.savedRecording?.durationSec, 25)
        XCTAssertEqual(rig.controller.endNotice, CaptureEndWatch.microphoneChangedMessage)
    }

    /// The watch the device engine uses: this engine's configuration change
    /// and a media-services reset end the capture; another engine's change
    /// does not; a cancelled watch is silent.
    func testTheCaptureEndWatchMapsTheAudioStackNotifications() {
        let center = NotificationCenter()
        let engine = NSObject()
        var ended: [String] = []
        let watch = CaptureEndWatch(center: center, engine: engine) { ended.append($0) }

        center.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        XCTAssertTrue(ended.isEmpty, "another engine's change is not ours")
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertEqual(ended, [CaptureEndWatch.microphoneChangedMessage, CaptureEndWatch.servicesResetMessage])

        watch.cancel()
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(ended.count, 2)
    }

    /// A file with no readable audio after Stop is not uploaded: it fails
    /// as unrecoverable, with no Retry.
    func testAStopWithNoReadableAudioFailsWithoutUploading() async throws {
        let rig = try makeRecorderRig()
        rig.engine.fileDuration = nil
        await rig.controller.recordVoiceNote()
        rig.clock.advance(60)
        await rig.controller.stop()

        XCTAssertEqual(rig.controller.phase, .failed(RecordingUploader.unrecoverableMessage))
        let row = try XCTUnwrap(try rig.store.phoneRecordings().first)
        XCTAssertEqual(row.failure, .unrecoverable)
        XCTAssertFalse(row.offersRetry)
        let uploads = try await relayUploads(in: rig.transport)
        XCTAssertTrue(uploads.isEmpty)
    }
}
