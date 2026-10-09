import XCTest
@testable import WatchtowerSync

/// The phone upload state machine: waiting → uploading → delivered/failed,
/// including the degenerate branches (zero-length capture, retry after
/// relaunch, ack after local delete). Dates derive from Date() — no
/// hardcoded wall-clock values.
final class RecordingUploaderTests: XCTestCase {
    private static let deviceID = "device-a"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-uploader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeAudioFile(name: String = "capture.m4a", bytes: Int = 64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private func makeStack(
        transport: any CloudSyncTransport = InMemoryCloudTransport()
    ) throws -> (RecordingUploader, ReplicaStore, any CloudSyncTransport) {
        let store = try ReplicaStore.inMemory()
        return (RecordingUploader(transport: transport, store: store, directory: dir, deviceID: Self.deviceID), store, transport)
    }

    /// Registers `file` as a capture that ended just now and lasted
    /// `duration` seconds, then unwraps the resulting ledger row.
    private func register(
        _ uploader: RecordingUploader,
        file: URL,
        duration: TimeInterval = 30,
        titleHint: String? = nil
    ) async throws -> PhoneRecording {
        let ended = Date()
        let result = try await uploader.register(
            fileURL: file, startedAt: ended.addingTimeInterval(-duration), endedAt: ended, titleHint: titleHint
        )
        return try XCTUnwrap(result)
    }

    private func echo(
        for recording: PhoneRecording,
        status: RecordingUploadStatus,
        errorMessage: String? = nil
    ) -> RecordingUploadPayload {
        var payload = RecordingUploadPayload(
            id: recording.id,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt,
            durationSec: recording.durationSec,
            titleHint: recording.titleHint,
            sampleFormat: recording.sampleFormat
        )
        payload.status = status
        payload.errorMessage = errorMessage
        return payload
    }

    // MARK: - Happy path

    func testRegisterUploadAckThenDelete() async throws {
        let (uploader, store, transport) = try makeStack()
        let file = try makeAudioFile()

        let recording = try await register(uploader, file: file, duration: 120, titleHint: "  Standup  ")
        XCTAssertEqual(recording.state, .waiting)
        XCTAssertEqual(recording.titleHint, "Standup") // trimmed
        XCTAssertEqual(recording.durationSec, 120)

        let sent = try await uploader.uploadPending()
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)

        // The relay record carries the asset and a pending payload.
        let batch = try await transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(batch.changed.first { $0.recordName == "recupload-\(recording.id)" })
        XCTAssertEqual(record.kind, "recording_upload")
        XCTAssertEqual(record.assetFileURL, file)
        let payload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
        XCTAssertEqual(payload.status, .pending)
        XCTAssertEqual(payload.durationSec, 120)

        // Hub ack: received → delivered, and ONLY now the local file goes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await uploader.applyEcho(echo(for: recording, status: .received))
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Degenerate captures

    func testZeroLengthRecordingIsDiscarded() async throws {
        let (uploader, store, _) = try makeStack()
        let file = dir.appendingPathComponent("empty.m4a")
        try Data().write(to: file)
        let ended = Date()
        let result = try await uploader.register(
            fileURL: file, startedAt: ended.addingTimeInterval(-30), endedAt: ended, titleHint: nil
        )
        XCTAssertNil(result)
        XCTAssertTrue(try store.phoneRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSubSecondRecordingIsDiscarded() async throws {
        // Valid-but-degenerate: a real (non-empty) file whose capture lasted
        // under the minimum — a tap on Record followed by an immediate stop.
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile(name: "blip.m4a")
        let ended = Date()
        let result = try await uploader.register(
            fileURL: file, startedAt: ended.addingTimeInterval(-0.4), endedAt: ended, titleHint: nil
        )
        XCTAssertNil(result)
        XCTAssertTrue(try store.phoneRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Retry paths

    func testRelaunchResendsUndeliveredUploads() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let file = try makeAudioFile()

        let first = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID)
        let recording = try await register(first, file: file, duration: 60)
        _ = try await first.uploadPending()

        // "Relaunch": a fresh uploader over the same store re-sends the
        // still-uploading row (the hub's processed-set absorbs duplicates).
        let second = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID)
        let resent = try await second.uploadPending()
        XCTAssertEqual(resent, 1)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)

        // Two save events landed for the SAME record name (latest wins in
        // the change feed, and the token proves both writes happened).
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.filter { $0.recordName == "recupload-\(recording.id)" }.count, 1)
        XCTAssertEqual(batch.newToken.value, 2)
    }

    // MARK: - One save per recording (no re-send of in-flight uploads)

    /// After the launch pass, a pass re-saves only `waiting` rows: an
    /// `uploading` row is already in the transport's durable send queue,
    /// and re-saving it (a new stamp and a new asset) would block the
    /// queue's clear and upload the audio again.
    func testEachRecordingIsSavedOnceAcrossPasses() async throws {
        let spy = SpyTransport()
        let (uploader, _, _) = try makeStack(transport: spy)
        let first = try await register(uploader, file: try makeAudioFile(name: "one.m4a"))
        _ = try await uploader.uploadPending()
        let second = try await register(uploader, file: try makeAudioFile(name: "two.m4a"))
        _ = try await uploader.uploadPending()

        let saves = await spy.savedNames
        XCTAssertEqual(saves.filter { $0 == "recupload-\(first.id)" }.count, 1)
        XCTAssertEqual(saves.filter { $0 == "recupload-\(second.id)" }.count, 1)
    }

    /// Two passes that overlap (a capture's stop while the launch pass is
    /// still sending) merge: the second never sends a row the first is
    /// sending.
    func testOverlappingPassesNeverSaveARecordingTwice() async throws {
        let spy = SpyTransport()
        await spy.holdSaves()
        let (uploader, _, _) = try makeStack(transport: spy)
        let first = try await register(uploader, file: try makeAudioFile(name: "one.m4a"))
        let second = try await register(uploader, file: try makeAudioFile(name: "two.m4a"))

        let passA = Task { try await uploader.uploadPending() }
        try await eventually { await spy.heldCount == 1 }
        let passB = Task { try await uploader.uploadPending() }
        // A pass that does not wait for A reaches the transport at once.
        _ = try? await eventually(timeout: 0.5) { await spy.heldCount > 1 }
        await spy.release()
        _ = try await passA.value
        _ = try await passB.value

        let saves = await spy.savedNames
        XCTAssertEqual(saves.filter { $0 == "recupload-\(first.id)" }.count, 1)
        XCTAssertEqual(saves.filter { $0 == "recupload-\(second.id)" }.count, 1)
    }

    /// The launch pass of a new process re-sends an `uploading` row once —
    /// the relaunch retry — and later passes leave it alone.
    func testTheLaunchPassResendsAnUploadingRowOnce() async throws {
        let store = try ReplicaStore.inMemory()
        let before = RecordingUploader(transport: InMemoryCloudTransport(), store: store, directory: dir, deviceID: Self.deviceID)
        let recording = try await register(before, file: try makeAudioFile())
        _ = try await before.uploadPending()
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)

        let spy = SpyTransport()
        let relaunched = RecordingUploader(transport: spy, store: store, directory: dir, deviceID: Self.deviceID)
        let launch = try await relaunched.uploadPending()
        let later = try await relaunched.uploadPending()

        XCTAssertEqual(launch, 1)
        XCTAssertEqual(later, 0)
        let saves = await spy.savedNames
        XCTAssertEqual(saves, ["recupload-\(recording.id)"])
    }

    /// The launch pass waits for a link: a pass without a device sends
    /// nothing and does not use up the re-send of in-flight rows.
    func testTheLaunchResendWaitsForALinkedDevice() async throws {
        let store = try ReplicaStore.inMemory()
        let before = RecordingUploader(transport: InMemoryCloudTransport(), store: store, directory: dir, deviceID: Self.deviceID)
        let recording = try await register(before, file: try makeAudioFile())
        _ = try await before.uploadPending()

        let spy = SpyTransport()
        let relaunched = RecordingUploader(transport: spy, store: store, directory: dir, deviceID: nil)
        _ = try await relaunched.uploadPending()
        await relaunched.setDeviceID(Self.deviceID)
        _ = try await relaunched.uploadPending()

        let saves = await spy.savedNames
        XCTAssertEqual(saves, ["recupload-\(recording.id)"])
    }

    /// A wiped transport store lost its send queue: the next pass re-sends
    /// every `uploading` row once more.
    func testAfterAWipeTheNextPassResendsUploadingRows() async throws {
        let spy = SpyTransport()
        let (uploader, _, _) = try makeStack(transport: spy)
        let recording = try await register(uploader, file: try makeAudioFile())
        _ = try await uploader.uploadPending()
        _ = try await uploader.uploadPending()

        await uploader.resendInFlightAfterWipe()
        _ = try await uploader.uploadPending()
        _ = try await uploader.uploadPending()

        let saves = await spy.savedNames
        XCTAssertEqual(saves, ["recupload-\(recording.id)", "recupload-\(recording.id)"])
    }

    /// Polls `condition` until it holds or `timeout` passes (then throws).
    private func eventually(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { throw EventuallyTimedOut() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTransportFailureLeavesRowForNextPass() async throws {
        let (uploader, store, _) = try makeStack(transport: FailingTransport())
        let file = try makeAudioFile()
        let recording = try await register(uploader, file: file)
        let sent = try await uploader.uploadPending()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .waiting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testVanishedLocalFileFailsRowLocally() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let recording = try await register(uploader, file: file)
        try FileManager.default.removeItem(at: file)
        _ = try await uploader.uploadPending()
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .failed)
        XCTAssertNotNil(row.errorMessage)
    }

    func testFailedEchoThenRetry() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let recording = try await register(uploader, file: file)
        _ = try await uploader.uploadPending()

        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "disk full"))
        var row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, "disk full")
        // The local file survives a failed ingest — it is the only copy.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try await uploader.retryFailed(id: recording.id)
        row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .uploading)
        XCTAssertNil(row.errorMessage)
    }

    // MARK: - Echo degenerates

    func testAckForUnknownIDIsANoOp() async throws {
        // Redelivery after the row was locally removed (ack after delete).
        let (uploader, store, _) = try makeStack()
        let ended = Date()
        var orphanEcho = RecordingUploadPayload(
            id: "GONE",
            startedAt: ended.addingTimeInterval(-60),
            endedAt: ended,
            durationSec: 60,
            titleHint: nil,
            sampleFormat: "aac-64k-mono"
        )
        orphanEcho.status = .received
        try await uploader.applyEcho(orphanEcho)
        XCTAssertTrue(try store.phoneRecordings().isEmpty)
    }

    func testOwnPendingEchoIsInert() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let recording = try await register(uploader, file: file)
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .pending))
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testLateFailedEchoNeverDowngradesDelivered() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let recording = try await register(uploader, file: file)
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .received))
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "stale duplicate"))
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .delivered)
    }

    // MARK: - Event link, device id, marks (mobile POC spec §5.3)

    private func uploadedPayload(
        _ recording: PhoneRecording,
        transport: any CloudSyncTransport
    ) async throws -> (RecordingUploadPayload, [String: Any]) {
        let batch = try await transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(batch.changed.first { $0.recordName == "recupload-\(recording.id)" })
        let payload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        return (payload, object)
    }

    func testEventIDAndDeviceIDTravelInThePayload() async throws {
        let (uploader, store, transport) = try makeStack()
        let ended = Date()
        let registered = try await uploader.register(
            fileURL: try makeAudioFile(), startedAt: ended.addingTimeInterval(-60), endedAt: ended,
            titleHint: "Design sync", eventID: "evt-7"
        )
        let recording = try XCTUnwrap(registered)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.eventID, "evt-7")
        _ = try await uploader.uploadPending()

        let (payload, object) = try await uploadedPayload(recording, transport: transport)
        XCTAssertEqual(payload.eventID, "evt-7")
        XCTAssertEqual(payload.deviceID, Self.deviceID)
        XCTAssertEqual(object["event_id"] as? String, "evt-7")
        XCTAssertEqual(object["device_id"] as? String, Self.deviceID)
    }

    func testVoiceNoteLeavesEventIDAbsent() async throws {
        let (uploader, _, transport) = try makeStack()
        let recording = try await register(uploader, file: try makeAudioFile())
        XCTAssertNil(recording.eventID)
        _ = try await uploader.uploadPending()

        let (payload, object) = try await uploadedPayload(recording, transport: transport)
        XCTAssertNil(payload.eventID)
        XCTAssertNil(object["event_id"], "a nil event id is an absent key, never null")
    }

    func testNothingIsSentWithoutALinkedDevice() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let uploader = RecordingUploader(transport: transport, store: store)
        let recording = try await register(uploader, file: try makeAudioFile())

        let sent = try await uploader.uploadPending()
        XCTAssertEqual(sent, 0, "the hub fails an upload without a device id as device_not_linked")
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .waiting)
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)

        await uploader.setDeviceID(Self.deviceID)
        let resent = try await uploader.uploadPending()
        XCTAssertEqual(resent, 1, "linking later sends the waiting recording")
    }

    func testMarksAreStoredLocallyAndNeverUploaded() async throws {
        let (uploader, store, transport) = try makeStack()
        let ended = Date()
        let registered = try await uploader.register(
            fileURL: try makeAudioFile(), startedAt: ended.addingTimeInterval(-300), endedAt: ended,
            titleHint: nil, marks: [125, 12, 125, 240]
        )
        let recording = try XCTUnwrap(registered)
        XCTAssertEqual(try store.phoneRecordingMarks(id: recording.id), [12, 125, 240])
        _ = try await uploader.uploadPending()

        let (_, object) = try await uploadedPayload(recording, transport: transport)
        let keys = Set(object.keys)
        XCTAssertFalse(keys.contains { $0.contains("mark") }, "marks stay on the phone: \(keys)")
        XCTAssertEqual(keys, [
            "id", "started_at", "ended_at", "duration_sec", "sample_format", "status", "device_id"
        ])
    }

    func testActiveDurationExcludesPausesAndDecidesTooShort() async throws {
        let (uploader, store, _) = try makeStack()
        let ended = Date()
        let registered = try await uploader.register(
            fileURL: try makeAudioFile(), startedAt: ended.addingTimeInterval(-600), endedAt: ended,
            activeDuration: 420, titleHint: nil
        )
        let recording = try XCTUnwrap(registered)
        XCTAssertEqual(recording.durationSec, 420, "a paused gap is not audio")

        let file = try makeAudioFile(name: "paused.m4a")
        let blip = try await uploader.register(
            fileURL: file, startedAt: ended.addingTimeInterval(-600), endedAt: ended,
            activeDuration: 0, titleHint: nil
        )
        XCTAssertNil(blip, "wall-clock time while paused does not make a recording long enough")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try store.phoneRecordings().count, 1)
    }

    func testOversizedAssetFailsLocallyWithoutSending() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let uploader = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID, maxAssetBytes: 32)
        let file = try makeAudioFile(bytes: 64)
        let recording = try await register(uploader, file: file)

        let sent = try await uploader.uploadPending()
        XCTAssertEqual(sent, 0)
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, RecordingUploader.tooLargeMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the only copy is kept")
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
    }

    func testRemovingARecordingRemovesItsMarks() async throws {
        let (uploader, store, _) = try makeStack()
        let ended = Date()
        let registered = try await uploader.register(
            fileURL: try makeAudioFile(), startedAt: ended.addingTimeInterval(-60), endedAt: ended,
            titleHint: nil, marks: [5]
        )
        let recording = try XCTUnwrap(registered)
        try await uploader.discard(id: recording.id)
        XCTAssertTrue(try store.phoneRecordingMarks(id: recording.id).isEmpty)
    }

    // MARK: - Capture lifecycle and launch recovery (a kill never loses audio)

    func testBeginCaptureWritesARecordingRowThatUploadsNothing() async throws {
        let (uploader, store, transport) = try makeStack()
        let file = try makeAudioFile()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: Date(), titleHint: "Design sync", eventID: "evt-1")
        XCTAssertEqual(try store.phoneRecording(id: row.id)?.state, .recording)
        let sent = try await uploader.uploadPending()
        XCTAssertEqual(sent, 0, "a capture still being written is never sent")
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
    }

    func testFinishCaptureFinalizesWithTheLastTitleEventAndMarks() async throws {
        let (uploader, store, _) = try makeStack()
        let started = Date()
        let row = try await uploader.beginCapture(fileURL: try makeAudioFile(), startedAt: started, titleHint: "Design sync", eventID: "evt-1")
        try await uploader.addMark(id: row.id, offsetSec: 4)
        let finished = try await uploader.finishCapture(
            id: row.id, endedAt: started.addingTimeInterval(90), activeDuration: 60,
            titleHint: "Voice note", eventID: nil, marks: [4, 50]
        )
        let done = try XCTUnwrap(finished)
        XCTAssertEqual(done.state, .waiting)
        XCTAssertEqual(done.durationSec, 60)
        XCTAssertNil(done.eventID, "switched to No meeting before Stop")
        XCTAssertEqual(done.titleHint, "Voice note")
        XCTAssertEqual(try store.phoneRecordingMarks(id: row.id), [4, 50])
    }

    func testFinishCaptureUnderASecondRemovesRowAndFile() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: Date(), titleHint: nil, eventID: nil)
        let finished = try await uploader.finishCapture(
            id: row.id, endedAt: Date(), activeDuration: 0, titleHint: nil, eventID: nil
        )
        XCTAssertNil(finished)
        XCTAssertTrue(try store.phoneRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRelaunchFinalizesACaptureCutShortWithTheFilesDuration() async throws {
        let (uploader, store, _) = try makeStack()
        let started = Date().addingTimeInterval(-3_600)
        let file = try makeAudioFile()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: started, titleHint: "Design sync", eventID: "evt-1")
        try await uploader.addMark(id: row.id, offsetSec: 30)

        let recovered = try await relaunched(store).recoverInterruptedCaptures { _ in 1_234.4 }

        XCTAssertEqual(recovered.map(\.id), [row.id])
        let done = try XCTUnwrap(try store.phoneRecording(id: row.id))
        XCTAssertEqual(done.state, .waiting)
        XCTAssertEqual(done.durationSec, 1_234, "the duration comes from the file")
        XCTAssertEqual(done.endedAt.timeIntervalSince1970, started.addingTimeInterval(1_234.4).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(done.eventID, "evt-1")
        XCTAssertEqual(try store.phoneRecordingMarks(id: row.id), [30], "marks tapped before the kill survive")
        let sent = try await uploader.uploadPending()
        XCTAssertEqual(sent, 1)
    }

    /// A capture begun in this process is never claimed by recovery, even
    /// with no id passed in (the Record-during-launch-recovery race); a new
    /// process (a relaunch) does recover it.
    func testRecoveryNeverTouchesACaptureBegunInThisProcess() async throws {
        let (uploader, store, transport) = try makeStack()
        let file = dir.appendingPathComponent("live.m4a")
        let row = try await uploader.beginCapture(fileURL: file, startedAt: Date(), titleHint: nil, eventID: nil)
        // The writer has not created the file yet: a claim would fail it.
        let recovered = try await uploader.recoverInterruptedCaptures { _ in nil }
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(try store.phoneRecording(id: row.id)?.state, .recording)
        _ = try await uploader.sweepOrphanFiles()

        try Data(repeating: 1, count: 32).write(to: file)
        let relaunched = RecordingUploader(transport: transport, store: store, directory: dir, deviceID: Self.deviceID)
        let after = try await relaunched.recoverInterruptedCaptures { _ in 60 }
        XCTAssertEqual(after.map(\.id), [row.id])
    }

    func testRecoveryWithTheFileGoneFailsWithoutRetry() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: Date(), titleHint: nil, eventID: nil)
        try FileManager.default.removeItem(at: file)

        _ = try await relaunched(store).recoverInterruptedCaptures { _ in 60 }

        let failed = try XCTUnwrap(try store.phoneRecording(id: row.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.errorMessage, RecordingUploader.missingFileMessage)
        XCTAssertEqual(failed.failure, .missingFile)
        XCTAssertFalse(failed.offersRetry)
        try await uploader.retryFailed(id: row.id)
        XCTAssertEqual(try store.phoneRecording(id: row.id)?.state, .failed, "Retry is a no-op for a permanent local failure")
    }

    func testRecoveryOfAFileWithNoAudioFailsAndDeletesIt() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: Date(), titleHint: nil, eventID: nil)
        _ = try await relaunched(store).recoverInterruptedCaptures { _ in nil }
        let failed = try XCTUnwrap(try store.phoneRecording(id: row.id))
        XCTAssertEqual(failed.errorMessage, RecordingUploader.unrecoverableMessage)
        XCTAssertFalse(failed.offersRetry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRecoveryUnderASecondRemovesTheRow() async throws {
        let (uploader, store, _) = try makeStack()
        let row = try await uploader.beginCapture(fileURL: try makeAudioFile(), startedAt: Date(), titleHint: nil, eventID: nil)
        _ = try await relaunched(store).recoverInterruptedCaptures { _ in 0.4 }
        XCTAssertNil(try store.phoneRecording(id: row.id))
    }

    func testOrphanSweepDeletesOnlyFilesWithoutARow() async throws {
        let (uploader, _, _) = try makeStack()
        let kept = try makeAudioFile(name: "kept.m4a")
        _ = try await register(uploader, file: kept)
        let orphan = try makeAudioFile(name: "orphan.m4a")

        let removed = try await uploader.sweepOrphanFiles()

        XCTAssertEqual(removed.map(\.lastPathComponent), ["orphan.m4a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testOnlyARemoteFailureOffersRetry() async throws {
        let (uploader, store, _) = try makeStack()
        let recording = try await register(uploader, file: try makeAudioFile())
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "disk full"))
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.offersRetry, true)

        let small = RecordingUploader(
            transport: InMemoryCloudTransport(), store: store, directory: dir, deviceID: Self.deviceID, maxAssetBytes: 1
        )
        let big = try await register(small, file: try makeAudioFile(name: "big.m4a"))
        _ = try await small.uploadPending()
        XCTAssertEqual(try store.phoneRecording(id: big.id)?.offersRetry, false, "over 90 MB stays over 90 MB")
    }

    func testRegisterKeepsAGivenID() async throws {
        let (uploader, _, _) = try makeStack()
        let ended = Date()
        let registered = try await uploader.register(
            id: "demo-recording", fileURL: try makeAudioFile(), startedAt: ended.addingTimeInterval(-60), endedAt: ended, titleHint: nil
        )
        XCTAssertEqual(registered?.id, "demo-recording")
    }

    /// The uploader of a new process over the same replica: it has begun
    /// no capture, so every `recording` row is a capture cut short.
    private func relaunched(_ store: ReplicaStore) -> RecordingUploader {
        RecordingUploader(transport: InMemoryCloudTransport(), store: store, directory: dir, deviceID: Self.deviceID)
    }

    // MARK: - Relative paths (iOS may move the container)

    func testAFileInTheRecordingsFolderIsStoredByName() async throws {
        let (uploader, _, _) = try makeStack()
        let inside = try await register(uploader, file: try makeAudioFile(name: "in.m4a"))
        XCTAssertEqual(inside.storedPath, "in.m4a")

        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString).m4a")
        try Data(repeating: 1, count: 16).write(to: elsewhere)
        addTeardownBlock { try? FileManager.default.removeItem(at: elsewhere) }
        let outside = try await register(uploader, file: elsewhere)
        XCTAssertEqual(outside.storedPath, elsewhere.path, "a file kept elsewhere keeps its absolute path")
    }

    /// The container moves between launches: every file is in a folder
    /// with a new absolute base. Nothing is deleted, recovery finds the
    /// stranded capture, and the upload sends the file from its new place.
    func testAMovedRecordingsFolderKeepsEveryFile() async throws {
        let (uploader, store, transport) = try makeStack()
        let saved = try await register(uploader, file: try makeAudioFile(name: "saved.m4a"))
        let stranded = try await uploader.beginCapture(
            fileURL: try makeAudioFile(name: "stranded.m4a"), startedAt: Date(), titleHint: nil, eventID: nil
        )
        let moved = try moveFolder()

        let relaunched = RecordingUploader(transport: transport, store: store, directory: moved, deviceID: Self.deviceID)
        let recovered = try await relaunched.recoverInterruptedCaptures { _ in 60 }
        let removed = try await relaunched.sweepOrphanFiles()
        let sent = try await relaunched.uploadPending()

        XCTAssertEqual(recovered.map(\.id), [stranded.id])
        XCTAssertTrue(removed.isEmpty, "a moved container must not look like orphans")
        XCTAssertEqual(sent, 2)
        let assets = try await transport.changes(in: .relay, since: nil).changed.compactMap(\.assetFileURL)
        XCTAssertEqual(Set(assets.map(\.lastPathComponent)), ["saved.m4a", "stranded.m4a"])
        XCTAssertTrue(assets.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try store.phoneRecording(id: saved.id)?.state, .uploading)
    }

    /// A row written by an older build holds an absolute path into the old
    /// container. It is rewritten to the bare name and found in the new one.
    func testALegacyAbsolutePathIsMovedToTheCurrentFolder() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let old = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID)
        let legacy = try await register(old, file: try makeAudioFile(name: "legacy.m4a"))
        XCTAssertTrue(legacy.storedPath.hasPrefix("/"))
        let moved = try moveFolder()

        let current = RecordingUploader(transport: transport, store: store, directory: moved, deviceID: Self.deviceID)
        let removed = try await current.sweepOrphanFiles()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try store.phoneRecording(id: legacy.id)?.storedPath, "legacy.m4a")
        let sent = try await current.uploadPending()
        XCTAssertEqual(sent, 1)
    }

    /// The first echo of a launch can arrive before recovery or the sweep:
    /// it still resolves a legacy row against the CURRENT folder, so the
    /// delivered audio is deleted, not leaked in the moved container.
    func testAnEchoBeforeAnyOtherCallUsesTheMigratedPath() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let old = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID)
        let legacy = try await register(old, file: try makeAudioFile(name: "legacy.m4a"))
        let moved = try moveFolder()

        let current = RecordingUploader(transport: transport, store: store, directory: moved, deviceID: Self.deviceID)
        try await current.applyEcho(echo(for: legacy, status: .received))

        XCTAssertEqual(try store.phoneRecording(id: legacy.id)?.storedPath, "legacy.m4a")
        XCTAssertEqual(try store.phoneRecording(id: legacy.id)?.state, .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("legacy.m4a").path))
    }

    /// The owner's delete can come first too: it removes the file from
    /// the current folder.
    func testADiscardBeforeAnyOtherCallUsesTheMigratedPath() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let old = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID)
        let legacy = try await register(old, file: try makeAudioFile(name: "legacy.m4a"))
        let moved = try moveFolder()

        let current = RecordingUploader(transport: transport, store: store, directory: moved, deviceID: Self.deviceID)
        try await current.discard(id: legacy.id)

        XCTAssertNil(try store.phoneRecording(id: legacy.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("legacy.m4a").path))
    }

    /// A delivered row owns no file: audio left behind after its
    /// `received` echo (a failed delete) is swept like an orphan.
    func testTheSweepDeletesTheFileOfADeliveredRow() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile(name: "delivered.m4a")
        let recording = try await register(uploader, file: file)
        try store.setPhoneRecordingState(id: recording.id, state: .delivered)

        let removed = try await uploader.sweepOrphanFiles()

        XCTAssertEqual(removed.map(\.lastPathComponent), ["delivered.m4a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .delivered, "the row stays")
    }

    /// Moves the test's recordings folder to a new container, keeping its
    /// name (as iOS does when the container UUID changes).
    private func moveFolder() throws -> URL {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("container-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let moved = container.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: moved)
        return moved
    }

    // MARK: - Typed local failures

    func testFailCaptureIsUnrecoverableWithoutRetry() async throws {
        let (uploader, store, transport) = try makeStack()
        let file = try makeAudioFile()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: Date(), titleHint: nil, eventID: nil)
        try await uploader.failCapture(id: row.id)
        let failed = try XCTUnwrap(try store.phoneRecording(id: row.id))
        XCTAssertEqual(failed.failure, .unrecoverable)
        XCTAssertFalse(failed.offersRetry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try await uploader.uploadPending()
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty, "never uploaded")
    }

    /// Retry keys on the stored kind, not the text: a row failed by an
    /// older build, known only by its message, gets its kind.
    func testRetryKeysOnTheStoredFailureKind() async throws {
        let (uploader, store, _) = try makeStack()
        let recording = try await register(uploader, file: try makeAudioFile())
        try store.setPhoneRecordingState(id: recording.id, state: .failed, errorMessage: RecordingUploader.tooLargeMessage)
        XCTAssertTrue(try XCTUnwrap(try store.phoneRecording(id: recording.id)).offersRetry, "no kind stored yet")
        _ = try await uploader.sweepOrphanFiles()
        let upgraded = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(upgraded.failure, .tooLarge)
        XCTAssertFalse(upgraded.offersRetry)

        try store.setPhoneRecordingState(id: recording.id, state: .failed, errorMessage: "The file is over 90 MB", failure: nil)
        XCTAssertTrue(try XCTUnwrap(try store.phoneRecording(id: recording.id)).offersRetry, "a Mac failure's text never decides")
    }

    // MARK: - Discard

    func testDiscardRemovesRowAndFile() async throws {
        let (uploader, store, _) = try makeStack()
        let file = try makeAudioFile()
        let recording = try await register(uploader, file: file)
        try await uploader.discard(id: recording.id)
        XCTAssertTrue(try store.phoneRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

/// Transport whose saves always throw — the push-failure branch.
private actor FailingTransport: CloudSyncTransport {
    struct SaveFailed: Error {}

    func save(_ records: [CloudRecord]) async throws { throw SaveFailed() }
    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}
    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: CloudChangeToken(value: 0))
    }
}

private struct EventuallyTimedOut: Error {}

/// Transport that records every saved record name and, when told to,
/// holds each save until `release()` — the overlapping-pass branch.
private actor SpyTransport: CloudSyncTransport {
    private(set) var savedNames: [String] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    func holdSaves() { holding = true }

    func release() {
        holding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func save(_ records: [CloudRecord]) async throws {
        savedNames += records.map(\.recordName)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: CloudChangeToken(value: 0))
    }
}
