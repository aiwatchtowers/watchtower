import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Recordings list, the recap and the transcript (spec §13 C3): the
/// list states of a phone recording on its way, the ready entries from
/// `meeting_transcript`, the recap sections, the speaker transcript from
/// the `segments.json` asset and the phone's marks as jump points.
@MainActor
final class RecordingsWiringTests: XCTestCase {
    private let now = Date()
    private var calendar: Calendar { .current }

    // MARK: - Fixtures

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func heartbeat(updatedAt: Date) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt, appVersion: "1.0", hubID: "hub-acme", macName: "Acme Mac", flavor: .default,
            lastPublishAt: updatedAt, lastRelayAt: updatedAt, relayBacklog: 0, accounts: [],
            enabledAt: updatedAt.addingTimeInterval(-86_400), ownerUser: "_user-acme", sharing: .none
        )
    }

    /// One waiting phone recording in a fresh ledger (no linked device, so
    /// it stays waiting), with `marks`.
    private func ledger(
        title: String = "Acme sync",
        eventID: String? = "evt-1",
        marks: [Int] = []
    ) async throws -> (store: ReplicaStore, recording: PhoneRecording, uploader: RecordingUploader) {
        let store = try makePoolStore()
        let directory = try makeRecordingsDirectory()
        let uploader = RecordingUploader(transport: InMemoryCloudTransport(), store: store, directory: directory)
        let file = directory.appendingPathComponent("rec_\(UUID().uuidString).m4a")
        try Data([1, 2, 3]).write(to: file)
        let registered = try await uploader.register(
            fileURL: file, startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-60),
            titleHint: title, eventID: eventID, marks: marks
        )
        return (store, try XCTUnwrap(registered), uploader)
    }

    private func snapshot(of store: ReplicaStore) async throws -> PhoneRecordingsSnapshot {
        try await store.reader.read { db in try PhoneRecordingsSnapshot.read(from: db, store: store) }
    }

    private func transcript(
        id: Int,
        eventID: String? = nil,
        phoneRecordingID: String? = nil,
        created: Date? = nil,
        summary: String? = "The release stays on Friday.",
        decisions: [String] = [],
        actions: [String] = [],
        questions: [String] = [],
        clipped: Bool? = nil // swiftlint:disable:this discouraged_optional_boolean
    ) -> MeetingTranscript {
        let created = Self.iso.string(from: created ?? now.addingTimeInterval(-300))
        return MeetingTranscript(
            id: id, eventID: eventID, title: "Acme standup", durationSec: 872, createdAt: created, updatedAt: created,
            phoneRecordingID: phoneRecordingID, speakers: ["Colleague A", "Colleague B"], summary: summary,
            keyDecisions: decisions, actionItems: actions, openQuestions: questions, segmentsClipped: clipped
        )
    }

    private func segments(_ spans: [(Double, Double)]) -> [TranscriptSegment] {
        spans.enumerated().map { index, span in
            TranscriptSegment(startSec: span.0, endSec: span.1, speaker: index.isMultiple(of: 2) ? "Colleague A" : "Colleague B",
                              text: "Line \(index)")
        }
    }

    private func list(
        _ recordings: PhoneRecordingsSnapshot,
        transcripts: [MeetingTranscript] = [],
        seen: RecordingsSeen = RecordingsSeen(baseline: .distantPast, opened: [])
    ) -> RecordingsListModel {
        RecordingsListModel(
            recordings: recordings, replica: CalendarReplicaSnapshot(transcripts: transcripts),
            seen: seen, now: now, calendar: calendar
        )
    }

    // MARK: - List states

    func testAPendingRecordingWithAFreshHeartbeatSaysSending() async throws {
        let (store, recording, _) = try await ledger()
        var recordings = try await snapshot(of: store)
        recordings.heartbeat = heartbeat(updatedAt: now.addingTimeInterval(-30))

        let entry = try XCTUnwrap(list(recordings).inProgress.first)
        XCTAssertEqual(entry.id, "phone-\(recording.id)")
        XCTAssertEqual(entry.statusText, "Sending")
        XCTAssertNil(entry.transcriptID, "nothing to open yet")
    }

    func testAPendingRecordingWithAStaleHeartbeatWaitsForTheMacToWake() async throws {
        let (store, _, _) = try await ledger()
        var recordings = try await snapshot(of: store)
        recordings.heartbeat = heartbeat(updatedAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(list(recordings).inProgress.first?.statusText, "Waiting for the Mac to wake")

        recordings.heartbeat = nil
        XCTAssertEqual(list(recordings).inProgress.first?.statusText, "Waiting for the Mac to wake", "no heartbeat at all")
    }

    func testATranscribingJobShowsThePercentOnTheMac() async throws {
        let (store, recording, _) = try await ledger()
        var recordings = try await snapshot(of: store)
        recordings.jobs[recording.id] = RecordingJob(id: recording.id, status: .transcribing, percent: 37, updatedAt: now)

        let entry = try XCTUnwrap(list(recordings).inProgress.first)
        XCTAssertEqual(entry.statusText, "Transcribing on Mac · 37%")
        XCTAssertEqual(entry.tone, .purple)
    }

    func testADoneJobIsReadyAndOpensItsTranscript() async throws {
        let (store, recording, _) = try await ledger()
        var recordings = try await snapshot(of: store)
        recordings.jobs[recording.id] = RecordingJob(id: recording.id, status: .done, transcriptID: 77, updatedAt: now)

        // The transcript has not arrived yet: ready, nothing to open.
        let waiting = try XCTUnwrap(list(recordings).earlier.first)
        XCTAssertEqual(waiting.statusText, "Ready")
        XCTAssertNil(waiting.transcriptID)

        // It arrives: one entry, the phone recording's, that opens it.
        let model = list(recordings, transcripts: [transcript(id: 77)])
        XCTAssertTrue(model.inProgress.isEmpty)
        XCTAssertEqual(model.earlier.count, 1, "the transcript merges with its phone recording")
        XCTAssertEqual(model.earlier.first?.statusText, "Ready")
        XCTAssertEqual(model.earlier.first?.transcriptID, 77)
        XCTAssertEqual(model.earlier.first?.tone, .green)
    }

    func testARecordingMadeOnTheMacShowsUpOnceItsTranscriptArrives() throws {
        let model = list(PhoneRecordingsSnapshot(), transcripts: [transcript(id: 5)])
        let entry = try XCTUnwrap(model.earlier.first)
        XCTAssertEqual(entry.statusText, "Ready")
        XCTAssertEqual(entry.transcriptID, 5)
        XCTAssertTrue(entry.subtitle.contains("recorded on Mac"), entry.subtitle)
        XCTAssertEqual(list(PhoneRecordingsSnapshot()).emptyText, "No recordings yet")
    }

    func testAFailedUploadOffersRetry() async throws {
        let (store, recording, uploader) = try await ledger()
        try await uploader.applyEcho(RecordingUploadPayload(
            id: recording.id, startedAt: recording.startedAt, endedAt: recording.endedAt,
            durationSec: recording.durationSec, sampleFormat: recording.sampleFormat,
            status: .failed, errorMessage: "The Mac could not save the recording.", deviceID: nil
        ))
        let recordings = try await snapshot(of: store)
        let entry = try XCTUnwrap(list(recordings).inProgress.first)
        XCTAssertEqual(entry.statusText, "The Mac could not save the recording.")
        XCTAssertEqual(entry.tone, .red)
        XCTAssertTrue(entry.offersRetry)
    }

    // MARK: - New recaps

    func testNewCountsReadyRecapsTheOwnerHasNotOpened() throws {
        let defaults = try makeDefaults()
        let seen = RecordingsSeenStore(defaults: defaults, now: now.addingTimeInterval(-3_600))
        let older = transcript(id: 1, created: now.addingTimeInterval(-7_200))
        let fresh = transcript(id: 2, created: now.addingTimeInterval(-60))
        XCTAssertEqual(list(PhoneRecordingsSnapshot(), transcripts: [older, fresh], seen: seen.value).newCount, 1,
                       "a transcript from before the phone's first launch is not new")

        seen.markOpened(2)
        XCTAssertEqual(list(PhoneRecordingsSnapshot(), transcripts: [older, fresh], seen: seen.value).newCount, 0)
        // Survives a relaunch, and the baseline is not moved.
        let relaunched = RecordingsSeenStore(defaults: defaults, now: now)
        XCTAssertEqual(relaunched.value, seen.value)
        XCTAssertEqual(RecordingsListModel.pillText(newCount: 1), "Recordings · 1 new")
        XCTAssertEqual(RecordingsListModel.pillText(newCount: 0), "Recordings")
    }

    // MARK: - Recap

    func testARecapWithEmptyListsHidesThoseSections() throws {
        let recap = RecapModel(
            transcript: transcript(id: 1, decisions: ["Ship on Friday"], actions: [], questions: []),
            body: .segments(segments([(0, 10)])), marks: [], calendar: calendar, now: now
        )
        XCTAssertEqual(recap.sections.map(\.title), ["Decisions"])
        XCTAssertEqual(recap.summary, "The release stays on Friday.")

        let full = RecapModel(
            transcript: transcript(id: 1, decisions: ["Ship on Friday"], actions: ["Send the notes"], questions: ["Who owns QA?"]),
            body: .segments([]), marks: [], calendar: calendar, now: now
        )
        XCTAssertEqual(full.sections.map(\.title), ["Action items", "Decisions", "Open questions"])

        let bare = RecapModel(
            transcript: transcript(id: 1, summary: nil), body: .segments([]), marks: [], calendar: calendar, now: now
        )
        XCTAssertTrue(bare.sections.isEmpty)
        XCTAssertNil(bare.summary)
        XCTAssertEqual(bare.recapEmptyText, "No recap yet — your Mac writes it after the transcript")
    }

    func testMakeTargetIsNotShownOnTheRecap() {
        let recap = RecapModel(
            transcript: transcript(id: 1, actions: ["Send the notes", "Book the review"]),
            body: .segments(segments([(0, 10)])), marks: [], calendar: calendar, now: now
        )
        XCTAssertFalse(recap.allStrings.contains { $0.localizedCaseInsensitiveContains("target") }, "\(recap.allStrings)")
    }

    // MARK: - Transcript

    func testClippedSegmentsSayTheTranscriptIsShortened() {
        let clipped = RecapModel(
            transcript: transcript(id: 1, clipped: true), body: .segments(segments([(0, 10)])),
            marks: [], calendar: calendar, now: now
        )
        XCTAssertEqual(clipped.clippedNotice, "Transcript shortened — the full text is on the Mac")
        let whole = RecapModel(
            transcript: transcript(id: 1), body: .segments(segments([(0, 10)])), marks: [], calendar: calendar, now: now
        )
        XCTAssertNil(whole.clippedNotice)
    }

    func testALegacyTranscriptWithoutSegmentsShowsOneBlock() throws {
        // The hub publishes a legacy row as one segment without a speaker.
        let legacy = [TranscriptSegment(startSec: 0, endSec: 872, speaker: "", text: "The whole transcript text.")]
        let recap = RecapModel(transcript: transcript(id: 1), body: .segments(legacy), marks: [], calendar: calendar, now: now)
        XCTAssertEqual(recap.lines.count, 1)
        let line = try XCTUnwrap(recap.lines.first)
        XCTAssertNil(line.speaker)
        XCTAssertEqual(line.text, "The whole transcript text.")
    }

    func testAMarkAt125SecondsJumpsToTheSegmentCoveringIt() throws {
        let recap = RecapModel(
            transcript: transcript(id: 1), body: .segments(segments([(0, 60), (60, 130), (130, 200)])),
            marks: [125], calendar: calendar, now: now
        )
        let jump = try XCTUnwrap(recap.jumpPoints.first)
        XCTAssertEqual(jump.lineID, 1)
        XCTAssertEqual(jump.label, "2:05")
        XCTAssertEqual(jump.accessibilityLabel, "Jump to the mark at 2 minutes 5 seconds")
    }

    func testAMarkPastTheEndJumpsToTheLastSegment() throws {
        let recap = RecapModel(
            transcript: transcript(id: 1), body: .segments(segments([(0, 60), (60, 130), (130, 200)])),
            marks: [5_000], calendar: calendar, now: now
        )
        XCTAssertEqual(recap.jumpPoints.first?.lineID, 2)
    }

    func testAnUndecodableSegmentsAssetIsShownAsAnError() {
        let broken = TranscriptBody.load(asset: .data(Data("not json".utf8)))
        guard case .unreadable = broken else { return XCTFail("expected unreadable, got \(broken)") }
        let recap = RecapModel(transcript: transcript(id: 1), body: broken, marks: [125], calendar: calendar, now: now)
        XCTAssertTrue(recap.lines.isEmpty)
        XCTAssertEqual(recap.transcriptError, "The transcript could not be read on this phone.")
        XCTAssertTrue(recap.jumpPoints.allSatisfy { $0.lineID == nil }, "no line to jump to")

        XCTAssertEqual(TranscriptBody.load(asset: nil), .notArrived)
        XCTAssertEqual(
            RecapModel(transcript: transcript(id: 1), body: .notArrived, marks: [], calendar: calendar, now: now).transcriptError,
            "The transcript has not reached this phone yet."
        )
        guard case .unreadable = TranscriptBody.load(asset: .unreadable("gone")) else {
            return XCTFail("a failed asset copy must show as an error")
        }
    }

    /// End to end: the hub's record with its `segments.json` asset is
    /// hydrated, the loader reads the segments and the phone recording's
    /// marks through the transcript's `phone_recording_id`.
    func testTheSegmentsAssetAndThePhoneMarksReachTheRecap() async throws {
        let (store, recording, _) = try await ledger(marks: [125])
        let transport = InMemoryCloudTransport()
        let dir = try makeRecordingsDirectory()
        let asset = dir.appendingPathComponent("segments.json")
        let body = segments([(0, 60), (60, 130), (130, 200)])
        try RelayCoder.makeEncoder().encode(body).write(to: asset)
        let mirror = transcript(id: 9, phoneRecordingID: recording.id)
        try await transport.save([CloudRecord(
            recordName: mirror.recordName, zone: .data, kind: SliceKind.meetingTranscript.rawValue, modifiedAt: now,
            payload: try RelayCoder.makeEncoder().encode(mirror), assetFileURL: asset
        )])
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let replica = try await store.reader.read { db in try CalendarReplicaSnapshot.read(from: db, store: store) }
        let decoded = try XCTUnwrap(replica.transcripts.first)
        let recordings = try await snapshot(of: store)
        let loaded = try await RecapLoader.load(transcript: decoded, recordings: recordings, store: store)
        XCTAssertEqual(loaded.body, .segments(body))
        XCTAssertEqual(loaded.marks, [125])
    }

    func testTheDemoTranscriptCarriesItsSegments() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let replica = try await store.reader.read { db in try CalendarReplicaSnapshot.read(from: db, store: store) }
        let demo = try XCTUnwrap(replica.transcripts.first)
        let loaded = try await RecapLoader.load(transcript: demo, recordings: PhoneRecordingsSnapshot(), store: store)
        XCTAssertEqual(loaded.body, .segments(DemoSeed.demoSegments))
    }

    // MARK: - Routing

    func testSeeRecordingsOpensTheRecordingsList() async throws {
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .cloudKit,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory()
        ) { uploader in
            PhoneRecorderController(
                uploader: uploader, engine: FakeAudioEngine(), notificationCenter: NotificationCenter(),
                now: { Date() }, tickInterval: nil
            )
        }
        addTeardownBlock { @MainActor in env.stop() }
        env.navigation.tab = .workbench

        env.showRecordings()
        XCTAssertEqual(env.navigation.tab, .calendar)
        XCTAssertEqual(env.navigation.calendarPath, [.recordings])
        XCTAssertFalse(env.recorder.isPresented)

        env.navigation.calendarPath.append(.recap(3))
        env.showRecordings()
        XCTAssertEqual(env.navigation.calendarPath, [.recordings], "one list, never a stack of them")
    }
}
