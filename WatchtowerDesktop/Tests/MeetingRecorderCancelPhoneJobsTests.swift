import AVFoundation
import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Desktop's own transcription of a phone recording stops before the Go hub
/// adopts it (go hub plan 3 Task 22): `cancelPhoneRecordingJobs(audioNames:)`
/// cancels, awaits and forgets the jobs, never resumed or completed, rows
/// removed; a second call is a no-op.
@MainActor
final class MeetingRecorderCancelPhoneJobsTests: MeetingRecorderTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private let decodes = Counter()

    func testARunningJobIsCancelledAndAwaitedBeforeItSaves() async throws {
        let engine = GateEngine(texts: ["phone words"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let notifier = FakeNotifier()
        let center = try makeCenter(engine: engine, runner: runner, notifier: notifier)
        var finished = 0
        center.onJobFinished = { _, _ in finished += 1 }
        let ingested = try await ingest(center)
        var entered = engine.enteredStream.makeAsyncIterator()
        _ = await entered.next() // the job transcribes now

        var cancelled = false
        let cancel = Task {
            await center.cancelPhoneRecordingJobs(audioNames: [ingested.lastPathComponent])
            cancelled = true
        }
        await waitUntil("the job left the queue") { center.jobs.isEmpty }
        XCTAssertFalse(cancelled, "the cancel waits until the job's task ended")
        engine.release()
        await cancel.value

        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertNil(center.activeJobID, "no job of the file runs")
        await runEnqueuedMainActorWork()
        XCTAssertTrue(runner.invocations.isEmpty, "never saved")
        XCTAssertEqual(finished, 0, "never completed")
        XCTAssertTrue(notifier.failedReasons.isEmpty, "no failure notice for a cancelled job")
        XCTAssertFalse(hasPendingRow(ingested), "the pending row is removed")
        XCTAssertEqual(decodes.value, 1, "the file is not read again after the cancel")
        removeSidecars(ingested)
        try? FileManager.default.removeItem(at: ingested)
    }

    func testAQueuedJobIsWithdrawnAndTheQueueGoesOn() async throws {
        let engine = GateEngine(texts: ["first", "second"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = try makeCenter(engine: engine, runner: runner)
        let finishedOne = expectation(description: "the first job finished")
        center.onJobFinished = { _, _ in finishedOne.fulfill() }
        let first = try await ingest(center)
        var entered = engine.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        let second = try await ingest(center)
        XCTAssertEqual(center.jobs.count, 2)

        await center.cancelPhoneRecordingJobs(audioNames: [second.lastPathComponent])

        XCTAssertEqual(center.jobs.map(\.audioURL), [first], "only the listed file's job goes")
        engine.release()
        await fulfillment(of: [finishedOne], timeout: 10)
        XCTAssertEqual(runner.invocations.count, 1, "the other job still saves")
        XCTAssertFalse(hasPendingRow(second))
        for url in [first, second] {
            removeSidecars(url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testCancellingTwiceIsANoOp() async throws {
        let engine = GateEngine(texts: ["words"])
        let center = try makeCenter(engine: engine, runner: TranscriptCapturingRunner(stdout: recapOKEnvelope))
        let ingested = try await ingest(center)
        var entered = engine.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        let cancel = Task { await center.cancelPhoneRecordingJobs(audioNames: [ingested.lastPathComponent]) }
        engine.release()
        await cancel.value

        await center.cancelPhoneRecordingJobs(audioNames: [ingested.lastPathComponent])
        await center.cancelPhoneRecordingJobs(audioNames: [])

        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertTrue(center.recoverable.isEmpty)
        XCTAssertEqual(center.cancelledPhoneAudioNames, [ingested.lastPathComponent])
        removeSidecars(ingested)
        try? FileManager.default.removeItem(at: ingested)
    }

    /// The launch's resume path offers a recording with a pending row; once
    /// cancelled it is gone and a later pass never offers it again.
    func testACancelledRecordingIsNeverPickedUpAgain() async throws {
        let audio = recordingsDir.appendingPathComponent("rec_20261101_100000.m4a")
        try Data([0x00]).write(to: audio)
        try await pendingStore.begin(recording: audio.lastPathComponent, eventID: nil, title: "Phone",
                                     isPrivate: false, at: Date(timeIntervalSinceNow: -60))
        let center = try makeCenter(engine: GateEngine(texts: []), runner: nil)
        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.audioURL), [audio], "re-offered at launch from pending_transcripts")

        await center.cancelPhoneRecordingJobs(audioNames: [audio.lastPathComponent])

        XCTAssertTrue(center.recoverable.isEmpty)
        XCTAssertFalse(hasPendingRow(audio))
        await center.restorePendingOnLaunch()
        XCTAssertTrue(center.recoverable.isEmpty, "the resume path never offers it again")
        await center.retryTranscription(config: singleWindowConfig())
        XCTAssertTrue(center.jobs.isEmpty, "nothing to resume")
    }

    // MARK: - Harness

    private func makeCenter(
        engine: GateEngine,
        runner: CLIRunnerProtocol?,
        notifier: FakeNotifier = FakeNotifier()
    ) throws -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(engine) },
            diarizerFactory: { _ in FakeDiarizer() },
            decode: { [decodes] _ in
                decodes.bump()
                return [Float](repeating: 0, count: 4800)
            },
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
    }

    private func ingest(_ center: MeetingRecorderCenter) async throws -> URL {
        let source = try writeAACFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        return try await center.ingestPhoneRecording(audioURL: source, eventID: nil, title: "Phone",
                                                     config: singleWindowConfig())
    }

    /// 0.2 s AAC, mono, at 48 kHz — the phone recorder's format.
    private func writeAACFixture() throws -> URL {
        let sampleRate = 48_000.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-cancel-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ]
        let frames = Int(sampleRate * 0.2)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<frames { data[0][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5 }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        return url
    }
}
