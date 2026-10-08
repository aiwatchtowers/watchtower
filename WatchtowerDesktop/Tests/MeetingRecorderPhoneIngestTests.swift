import AVFoundation
import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A recording made on the phone (`.m4a`, mic only) relayed to the Mac: it
/// joins the `rec_*` family in the recordings directory and is transcribed by
/// the same queue as a Desktop recording — enqueued directly, never parked in
/// the opt-in recoverable list.
@MainActor
final class MeetingRecorderPhoneIngestTests: MeetingRecorderTestCase {

    // MARK: - Recovery and naming

    /// An app quit before the job ran leaves the `.m4a` with its `.meta`; the
    /// launch scan must offer it like a crashed Desktop recording.
    func testRecoveryScanFindsAnM4AWithItsSidecar() throws {
        let phone = recordingsDir.appendingPathComponent("rec_20260803_100000.m4a")
        try Data([0x00]).write(to: phone)
        try #"{"eventID":"evt-phone","title":"Phone"}"#
            .write(to: metaSidecar(phone), atomically: true, encoding: .utf8)
        let center = try makeCenter(runner: nil)

        center.restorePendingOnLaunch()

        XCTAssertEqual(center.recoverable.map(\.audioURL), [phone])
        XCTAssertEqual(center.recoverable.first?.eventID, "evt-phone")
        XCTAssertEqual(center.recoverable.first?.title, "Phone")
    }

    /// The sort key strips whichever extension the file has, so phone and
    /// Desktop recordings of the same second interleave chronologically.
    func testRecoveryScanOrdersMixedExtensionsChronologically() throws {
        let first = recordingsDir.appendingPathComponent("rec_20260803_100000.m4a")
        let second = recordingsDir.appendingPathComponent("rec_20260803_100000-2.m4a")
        let third = recordingsDir.appendingPathComponent("rec_20260803_100000-3.caf")
        let tenth = recordingsDir.appendingPathComponent("rec_20260803_100000-10.m4a")
        let nextSecond = recordingsDir.appendingPathComponent("rec_20260803_100001.caf")
        for audio in [nextSecond, tenth, third, second, first] {
            try Data([0x00]).write(to: audio)
            try Data("{}".utf8).write(to: metaSidecar(audio))
        }
        let center = try makeCenter(runner: nil)

        center.restorePendingOnLaunch()

        XCTAssertEqual(center.recoverable.map(\.audioURL), [first, second, third, tenth, nextSecond])
    }

    /// `.caf` and `.m4a` are the same length, so the scan above cannot tell
    /// `deletingPathExtension` from the old `dropLast(".caf".count)`; this pins
    /// the key itself on extensions of other lengths.
    func testRecoverySortKeyStripsAnExtensionOfAnyLength() {
        XCTAssertEqual(MeetingRecorderCenter.recoverySortKey("rec_20260803_100000-2.m4a").0, "rec_20260803_100000")
        XCTAssertEqual(MeetingRecorderCenter.recoverySortKey("rec_20260803_100000-2.m4a").1, 2)
        XCTAssertEqual(MeetingRecorderCenter.recoverySortKey("rec_20260803_100000-10.flac").0, "rec_20260803_100000")
        XCTAssertEqual(MeetingRecorderCenter.recoverySortKey("rec_20260803_100000-10.flac").1, 10)
        XCTAssertEqual(MeetingRecorderCenter.recoverySortKey("rec_20260803_100000.aac").0, "rec_20260803_100000")
        XCTAssertEqual(MeetingRecorderCenter.recoverySortKey("rec_20260803_100000.aac").1, 1)
    }

    /// `rec_X.caf` and `rec_X.m4a` would share every sidecar (`.meta`,
    /// `.txt`, `.json`, `.activity`), so a name is taken while either audio
    /// extension exists.
    func testUniqueRecordingURLSkipsANameTakenByEitherExtension() throws {
        let date = Date()
        let base = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date, fileExtension: "m4a")
        XCTAssertEqual(base.pathExtension, "m4a")
        XCTAssertTrue(base.lastPathComponent.hasPrefix("rec_"))
        let stem = base.deletingPathExtension().lastPathComponent

        // An existing phone recording pushes the next phone request to -2.
        try Data([0x00]).write(to: base)
        XCTAssertEqual(
            MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date, fileExtension: "m4a")
                .lastPathComponent,
            "\(stem)-2.m4a")
        try FileManager.default.removeItem(at: base)

        // A saved Desktop recording (no sidecar) of the same second.
        try Data([0x00]).write(to: recordingsDir.appendingPathComponent("\(stem).caf"))
        let phone = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date, fileExtension: "m4a")
        XCTAssertEqual(phone.lastPathComponent, "\(stem)-2.m4a")

        try Data([0x00]).write(to: phone)
        let desktop = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date)
        XCTAssertEqual(desktop.lastPathComponent, "\(stem)-3.caf",
                       "the default stays .caf and skips the phone recording's name")
    }

    // MARK: - Decode

    /// The batch path's real decoder reads the phone's AAC `.m4a` end to end.
    func testIngestedM4ADecodesToTheExpectedSampleCount() async throws {
        let source = try writePhoneAACFixture(durationSec: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        let counter = SampleCountingTranscriber()
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in counter },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let finished = expectFinished(center)

        try await center.ingestPhoneRecording(audioURL: source, eventID: nil, title: "Voice note",
                                              config: singleWindowConfig())
        await fulfillment(of: [finished], timeout: 10)

        let count = try XCTUnwrap(counter.sampleCounts.first)
        let expected = Double(TranscriptionConfig.sampleRate)
        XCTAssertEqual(Double(count), expected, accuracy: expected * 0.01,
                       "1 s of AAC decodes to 16 000 samples ±1 %")
    }

    // MARK: - Event link

    func testIngestWithAnEventLinksTheTranscriptAndScopesTheRegistry() async throws {
        let outcome = try await runIngest(eventID: "evt-1")

        XCTAssertEqual(outcome.runner.invocations.count, 1)
        let save = try XCTUnwrap(outcome.runner.invocations.first)
        XCTAssertEqual(savedFlag(save, "--event-id"), "evt-1")
        XCTAssertEqual(savedFlag(save, "--title"), "Standup")
        XCTAssertEqual(outcome.loaderEventIDs.values, ["evt-1"],
                       "attendee-scoped voice matching reads the event's invited set")
    }

    func testIngestWithoutAnEventSavesAnAdHocTranscript() async throws {
        let outcome = try await runIngest(eventID: nil)

        let save = try XCTUnwrap(outcome.runner.invocations.first)
        XCTAssertNil(savedFlag(save, "--event-id"), "an ad-hoc save omits --event-id")
        XCTAssertEqual(outcome.loaderEventIDs.values, [nil])
    }

    // MARK: - Mic only

    /// A phone recording has only the mic channel: no system channel and no
    /// `.activity` sidecar. Diarization still runs, the «Я» role is skipped
    /// (nothing to tell the owner's mic from the call), and the job saves.
    func testMicOnlyRecordingCompletesWithoutRolesAndWithoutFailure() async throws {
        let outcome = try await runIngest(eventID: nil)

        XCTAssertEqual(outcome.diarizer.calls, 1, "diarization runs on a mic-only recording")
        let saved = try XCTUnwrap(outcome.runner.savedTranscripts.first)
        XCTAssertFalse(saved.contains("[Я]"), "no activity sidecar → no owner role")
        XCTAssertTrue(saved.contains("[Speaker 1]"))
        XCTAssertTrue(outcome.notifier.failedReasons.isEmpty)
        XCTAssertEqual(outcome.notifier.readyTitles, ["Standup"])
        XCTAssertFalse(outcome.phases.contains { $0.isFailed })
        XCTAssertTrue(outcome.center.jobs.isEmpty, "the job saved and left the queue")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaSidecar(outcome.audioURL).path),
                       "a saved recording drops its recovery sidecar")
    }

    // MARK: - Callbacks

    func testCallbacksReportProgressAndTheTranscriptID() async throws {
        let source = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        // 12 windows of 0.1 s.
        let center = try makeCenter(runner: runner, decode: stubDecode(sampleCount: 19_200),
                                    texts: Array(repeating: "word", count: 12))
        var phases: [(URL, MeetingRecorderCenter.ProcessingJob.Phase)] = []
        center.onJobPhase = { url, phase in phases.append((url, phase)) }
        var finishes: [(URL, Int64)] = []
        let finished = expectation(description: "job finished")
        center.onJobFinished = { url, id in finishes.append((url, id)); finished.fulfill() }

        let ingested = try await center.ingestPhoneRecording(audioURL: source, eventID: nil, title: "Note",
                                                             config: threeWindowConfig())
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertTrue(phases.allSatisfy { $0.0 == ingested }, "phases are keyed by the ingested audio URL")
        XCTAssertTrue(phases.contains { $0.1 == .transcribing(done: 3, total: 12) },
                      "got \(phases.map(\.1))")
        XCTAssertEqual(phases.last?.1, .summarizing)
        XCTAssertEqual(finishes.map(\.0), [ingested])
        XCTAssertEqual(finishes.map(\.1), [7], "the transcript id from the save envelope")
    }

    // MARK: - Review focus 5: the Mac is capturing its own meeting

    /// A phone upload arriving mid-capture queues behind it: the capture is
    /// untouched (single-engine invariant) and the job runs only after Stop.
    func testIngestDuringADesktopCaptureQueuesBehindIt() async throws {
        let source = try makeDummyAudioFile()
        let desktopAudio = try makeDummyAudioFile()
        defer {
            for url in [source, desktopAudio] {
                try? FileManager.default.removeItem(at: url)
                removeSidecars(url)
            }
        }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: desktopAudio, durationSec: 1)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["transcript \(engineLoads)"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        var claimedWhileCapturing: [Bool] = []
        center.onEngineSlotClaimedForTesting = { claimedWhileCapturing.append(center.isCapturing) }
        let config = singleWindowConfig()

        await center.startRecording(eventID: "evt-desk", title: "Desk", config: config)
        let started = await waitUntil("the live pass to load") { center.liveEngineState == .running }
        guard started else { return }
        let captureBefore = center.captureState

        let ingested = try await center.ingestPhoneRecording(audioURL: source, eventID: nil, title: "Phone",
                                                             config: config)
        await runEnqueuedMainActorWork()

        XCTAssertEqual(center.captureState, captureBefore, "the capture is unchanged")
        XCTAssertEqual(center.liveEngineState, .running)
        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.stopCalls, 0, "an ingest never stops the capture")
        XCTAssertEqual(center.jobs.map(\.audioURL), [ingested])
        XCTAssertEqual(center.jobs.first?.phase, .queued, "the job waits for the engine slot")
        XCTAssertTrue(claimedWhileCapturing.isEmpty, "no job claims the engine while capturing")
        XCTAssertEqual(engineLoads, 1, "only the live pass's engine is resident")

        await center.stopAndProcess(config: config)
        let drained = await waitUntil("both jobs to save") { runner.invocations.count == 2 }
        guard drained else { return }

        XCTAssertEqual(claimedWhileCapturing, [false, false], "both jobs ran after the capture stopped")
        XCTAssertEqual(runner.invocations.map { savedFlag($0, "--title") }, ["Phone", "Desk"],
                       "FIFO: the phone job was queued first")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    // MARK: - Name reservation (concurrent writers)

    /// Writers off the main actor racing for the same second: the exclusive
    /// sidecar create gives each its own stem and no sidecar is overwritten.
    func testConcurrentReservationsOfTheSameSecondGetDistinctNames() async throws {
        let date = Date()
        let directory: URL = recordingsDir
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try MeetingRecorderCenter.reservePhoneRecording(
                        eventID: nil, title: "title \(index)", in: directory, date: date)
                }
            }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }

        XCTAssertEqual(Set(urls).count, 8, "every writer gets its own name")
        let titles = try urls.map { try sidecarTitle($0) }
        XCTAssertEqual(Set(titles), Set((0..<8).map { "title \($0)" }), "no sidecar was overwritten")
    }

    /// Two uploads of one sync batch ingested together, same clock second.
    func testConcurrentIngestsOfTheSameSecondBothLandAndQueue() async throws {
        let first = try makeDummyAudioFile()
        let second = try makeDummyAudioFile()
        defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }
        let fixed = Date()
        // No runner: both jobs fail at the save step, so their sidecars stay
        // on disk to be inspected.
        let center = try makeCenter(runner: nil) { fixed }
        let config = singleWindowConfig()

        async let one = center.ingestPhoneRecording(audioURL: first, eventID: "evt-a", title: "A", config: config)
        async let two = center.ingestPhoneRecording(audioURL: second, eventID: "evt-b", title: "B", config: config)
        let urls = try await [one, two]

        XCTAssertNotEqual(urls[0], urls[1])
        XCTAssertEqual(Set(center.jobs.map(\.audioURL)), Set(urls), "both jobs are enqueued")
        XCTAssertEqual(try urls.map { try sidecarTitle($0) }, ["A", "B"], "each keeps its own sidecar")
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        await waitUntil("both jobs to settle") { center.jobs.allSatisfy { $0.phase.isFailed } }
    }

    /// A Desktop recording of the same second already holds the stem: the
    /// ingest moves to -2 and leaves the Desktop sidecar alone.
    func testIngestSkipsADesktopRecordingOfTheSameSecond() async throws {
        let source = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let fixed = Date()
        let desktop = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: fixed)
        try #"{"eventID":"evt-desk","title":"Desk"}"#
            .write(to: metaSidecar(desktop), atomically: true, encoding: .utf8)
        let center = try makeCenter(runner: nil) { fixed }

        let ingested = try await center.ingestPhoneRecording(audioURL: source, eventID: nil, title: "Phone",
                                                             config: singleWindowConfig())

        let stem = desktop.deletingPathExtension().lastPathComponent
        XCTAssertEqual(ingested.lastPathComponent, "\(stem)-2.m4a")
        XCTAssertEqual(try sidecarTitle(desktop), "Desk", "the Desktop sidecar is untouched")
        XCTAssertEqual(try sidecarTitle(ingested), "Phone")
        await waitUntil("the job to settle") { center.jobs.allSatisfy { $0.phase.isFailed } }
    }

    /// A Desktop capture starting while an ingest arrives: both pick their
    /// names on the main actor, so the stems differ and neither sidecar is
    /// overwritten.
    func testIngestRacingADesktopStartGetsADistinctName() async throws {
        let source = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let recorder = FakeRecorder()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        var config = singleWindowConfig()
        config.liveTranscription = false

        async let start: Void = center.startRecording(eventID: "evt-desk", title: "Desk", config: config)
        async let ingest = center.ingestPhoneRecording(audioURL: source, eventID: nil, title: "Phone",
                                                       config: config)
        let ingested = try await ingest
        await start

        let desktop = try XCTUnwrap(recorder.lastStartURL)
        XCTAssertNotEqual(desktop.deletingPathExtension().lastPathComponent,
                          ingested.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(try sidecarTitle(desktop), "Desk")
        XCTAssertEqual(try sidecarTitle(ingested), "Phone")

        // Hygiene: end the capture so the parked ingest job runs out.
        recorder.stopResult = RecordingResult(audioURL: desktop, durationSec: 1)
        await center.stopAndProcess(config: config)
        await waitUntil("both jobs to settle") { center.jobs.allSatisfy { $0.phase.isFailed } }
    }

    /// A copy that fails (the source is gone) throws, enqueues nothing and
    /// leaves no sidecar behind.
    func testFailedCopyLeavesNothingBehind() async throws {
        let missing = recordingsDir.appendingPathComponent("missing-source.m4a")
        let center = try makeCenter(runner: nil)

        do {
            try await center.ingestPhoneRecording(audioURL: missing, eventID: nil, title: "Gone",
                                                  config: singleWindowConfig())
            XCTFail("the ingest must throw")
        } catch {}

        let names = try FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("rec_") }, "got \(names)")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    private func sidecarTitle(_ audio: URL) throws -> String? {
        struct Meta: Decodable { let title: String? }
        return try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaSidecar(audio))).title
    }

    // MARK: - Harness

    private func makeCenter(
        runner: CLIRunnerProtocol?,
        decode: @escaping @Sendable (URL) throws -> [Float] = { _ in [Float](repeating: 0, count: 4800) },
        texts: [String] = ["привет", "ответ"],
        diarizer: FakeDiarizer = FakeDiarizer(),
        now: @escaping () -> Date = Date.init
    ) throws -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: texts)) },
            diarizerFactory: { _ in diarizer },
            decode: decode,
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir,
            now: now
        )
    }

    private func expectFinished(_ center: MeetingRecorderCenter) -> XCTestExpectation {
        let finished = expectation(description: "job finished")
        center.onJobFinished = { _, _ in finished.fulfill() }
        return finished
    }

    private struct IngestOutcome {
        let center: MeetingRecorderCenter
        let runner: TranscriptCapturingRunner
        let notifier: FakeNotifier
        let diarizer: FakeDiarizer
        let loaderEventIDs: EventIDRecorder
        let phases: [MeetingRecorderCenter.ProcessingJob.Phase]
        let audioURL: URL
    }

    /// Ingest → batch transcription (3 windows) → fake diarizer → save, with
    /// the registry loader recording the event id it was asked for.
    private func runIngest(eventID: String?) async throws -> IngestOutcome {
        let source = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let notifier = FakeNotifier()
        let diarizer = FakeDiarizer()
        diarizer.segments = [
            SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.1),
            SpeakerSegment(speakerID: "B", startSec: 0.1, endSec: 0.25)
        ]
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["привет", "ответ"])) },
            diarizerFactory: { _ in diarizer },
            decode: stubDecode(sampleCount: 4800),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let recorder = EventIDRecorder()
        center.registryLoader = { id in
            recorder.append(id)
            return .empty
        }
        var phases: [MeetingRecorderCenter.ProcessingJob.Phase] = []
        center.onJobPhase = { _, phase in phases.append(phase) }
        let finished = expectFinished(center)
        var config = threeWindowConfig()
        config.diarization = true

        let ingested = try await center.ingestPhoneRecording(audioURL: source, eventID: eventID, title: "Standup",
                                                             config: config)
        XCTAssertEqual(ingested.pathExtension, "m4a")
        XCTAssertEqual(ingested.deletingLastPathComponent().standardizedFileURL,
                       recordingsDir.standardizedFileURL)
        XCTAssertTrue(center.recoverable.isEmpty, "a phone recording is never parked as recoverable")
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingested.path), "the audio is kept on disk")
        return IngestOutcome(center: center, runner: runner, notifier: notifier, diarizer: diarizer,
                             loaderEventIDs: recorder, phases: phases, audioURL: ingested)
    }

    /// 1 s AAC, mono, 64 kbps at 48 kHz — the phone recorder's format.
    private func writePhoneAACFixture(durationSec: Double) throws -> URL {
        let sampleRate = 48_000.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-fixture-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let frames = Int(sampleRate * durationSec)
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<frames {
            data[0][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        return url
    }
}

/// Records the event ids the registry loader was asked for (the loader is
/// `@Sendable` and runs off the main actor).
final class EventIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    func append(_ id: String?) { lock.withLock { storage.append(id) } }
    var values: [String?] { lock.withLock { storage } }
}

/// A transcriber that records how many samples it was handed and returns one
/// fixed segment, so the decode path is observable without a real engine.
final class SampleCountingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    var sampleCounts: [Int] { lock.withLock { counts } }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        lock.withLock { counts.append(samples.count) }
        return TranscriptionOutput(text: "voice note", langStats: ["en": 1])
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
