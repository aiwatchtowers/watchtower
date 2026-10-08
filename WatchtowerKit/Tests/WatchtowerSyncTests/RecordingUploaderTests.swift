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
        return (RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID), store, transport)
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
