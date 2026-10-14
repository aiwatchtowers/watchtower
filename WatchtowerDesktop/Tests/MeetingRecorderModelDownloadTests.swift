import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// `MeetingRecorderCenter` with the model provisioner wired (#744): a first
/// recording waits for the model's download (joining one already running),
/// and the warm policy never prewarms a model that is not on disk yet.
@MainActor
final class MeetingRecorderModelDownloadTests: MeetingRecorderTestCase {
    private let referenceNow = Date(timeIntervalSinceReferenceDate: 0)
    private let modelKey = TranscriptionModelProvisioner.ModelKey(providerID: "whisperkit", model: "large-v3")
    private var engineKey: () -> String { { "whisperkit|large-v3" } }

    private func warmDefaults() throws -> UserDefaults {
        let defaults = try isolatedDefaults()
        defaults.removeObject(forKey: MeetingRecorderCenter.preloadBeforeMeetingsKey)
        return defaults
    }

    private func provisioner(_ download: HeldDownload, defaults: UserDefaults) -> TranscriptionModelProvisioner {
        .forTests(download, defaults: defaults, label: "Large v3")
    }

    /// First use while the background download runs: the live pass waits
    /// for it — no engine load before the model lands, one download total —
    /// and the recording transcribes once it does.
    func testFirstRecordingWaitsForTheRunningDownloadThenTranscribes() async throws {
        let download = HeldDownload()
        let defaults = try isolatedDefaults()
        var engineLoads = 0
        let recorder = FakeRecorder()
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["after the download"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir,
            engineKey: engineKey
        )
        let models = provisioner(download, defaults: defaults)
        center.modelProvisioner = models
        models.ensureDownloaded(modelKey)
        await waitUntil("the background download to start") { download.isHeld }

        let config = singleWindowConfig()
        await center.startRecording(eventID: nil, title: "First", config: config)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(center.liveEngineState, .loading, "the live pass is waiting, not done")
        XCTAssertEqual(engineLoads, 0, "the engine must not load before its model is on disk")
        XCTAssertNotNil(models.download(for: modelKey), "the download stays visible while the recording waits")

        download.finish()
        await waitUntil("the live pass to load its engine") { engineLoads == 1 }
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(download.calls, 1, "the recording joins the running download")
        XCTAssertTrue(models.isDownloaded(modelKey))
        XCTAssertEqual(runner.savedTranscripts, ["after the download"])
    }

    /// Without the model on disk a meeting nearby does not prewarm — a
    /// prewarm must never start a silent download; once it is on disk it does.
    func testWarmPolicyPrewarmsOnlyAModelOnDisk() async throws {
        let download = HeldDownload()
        let defaults = try warmDefaults()
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["talk"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir,
            engineKey: engineKey,
            now: { self.referenceNow },
            meetingsProvider: { _ in WarmMeetingWindow(hasOngoingMeeting: true, nextStart: nil) }
        )
        let models = provisioner(download, defaults: defaults)
        center.modelProvisioner = models
        let config = singleWindowConfig()

        center.warmPolicyTick(config: config)
        XCTAssertFalse(center.isPrewarming, "no prewarm while the model is not on disk")
        XCTAssertEqual(download.calls, 0, "the tick must not start a download")

        models.ensureDownloaded(modelKey)
        await waitUntil("the download to start") { download.isHeld }
        download.finish()
        await models.task(for: modelKey)?.value

        center.warmPolicyTick(config: config)
        await waitUntil("the prewarm to park its engine") { center.isEngineWarm }
        XCTAssertEqual(engineLoads, 1)
    }

    /// A first recording whose download fails, all the way through: the live
    /// pass gives up (the pill shows the failure), Stop downloads again
    /// while the capture is already over, a second failure fails the job in
    /// plain words with the audio kept, and the job's Retry downloads and
    /// transcribes.
    func testFirstRecordingWhoseDownloadFailsFailsTheJobAndRetryRecovers() async throws {
        let download = HeldDownload()
        let defaults = try isolatedDefaults()
        var engineLoads = 0
        let recorder = FakeRecorder()
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["recovered"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir,
            engineKey: engineKey
        )
        let models = provisioner(download, defaults: defaults)
        center.modelProvisioner = models
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        await waitUntil("the live pass's download to start") { download.isHeld }
        download.failWith = URLError(.networkConnectionLost)
        download.finish()
        await waitUntil("the live pass to give up") { center.liveEngineState == .unavailable }
        guard case .failed = models.download(for: modelKey)?.state else {
            return XCTFail("the failed download stays on screen with Retry")
        }

        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        let stop = Task { await center.stopAndProcess(config: config) }
        await waitUntil("Stop to download again") { download.calls == 2 && download.isHeld }
        XCTAssertFalse(center.isCapturing, "the capture is over while the transcript waits for the model")
        download.failWith = URLError(.notConnectedToInternet)
        download.finish()
        await stop.value

        let job = try XCTUnwrap(center.jobs.first)
        guard case let .failed(message) = job.phase else { return XCTFail("expected a failed job, got \(job.phase)") }
        XCTAssertTrue(message.contains("connection dropped"), message)
        XCTAssertEqual(engineLoads, 0)
        XCTAssertTrue(runner.savedTranscripts.isEmpty)

        let retry = Task { await center.retryTranscription(config: config) }
        await waitUntil("the job's retry to download") { download.calls == 3 && download.isHeld }
        download.finish()
        await retry.value

        XCTAssertEqual(runner.savedTranscripts, ["recovered"])
        XCTAssertTrue(models.isDownloaded(modelKey))
        XCTAssertNil(models.download(for: modelKey))
    }
}
