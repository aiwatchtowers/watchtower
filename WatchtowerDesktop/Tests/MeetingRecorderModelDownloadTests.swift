import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A model download held until the test releases it.
@MainActor
private final class HeldDownload {
    private(set) var calls = 0
    private var release: CheckedContinuation<Void, Never>?

    func call(_: String, _: String, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1
        progress(0.25)
        await withCheckedContinuation { release = $0 }
    }

    var isHeld: Bool { release != nil }

    func finish() {
        release?.resume()
        release = nil
    }
}

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
        TranscriptionModelProvisioner(
            downloadFn: { try await download.call($0, $1, $2) },
            describe: { _ in (label: "Large v3", sizeBytes: nil) },
            defaults: defaults)
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
}
