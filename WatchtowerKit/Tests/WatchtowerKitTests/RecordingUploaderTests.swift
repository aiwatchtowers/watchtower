import XCTest
@testable import WatchtowerKit

/// The phone upload state machine: waiting → uploading → delivered/failed,
/// including the degenerate branches (zero-length capture, retry after
/// relaunch, ack after local delete). Dates derive from Date() — no
/// hardcoded wall-clock values.
final class RecordingUploaderTests: XCTestCase {
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
        return (RecordingUploader(transport: transport, store: store), store, transport)
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

        let first = RecordingUploader(transport: transport, store: store)
        let recording = try await register(first, file: file, duration: 60)
        _ = try await first.uploadPending()

        // "Relaunch": a fresh uploader over the same store re-sends the
        // still-uploading row (the hub's processed-set absorbs duplicates).
        let second = RecordingUploader(transport: transport, store: store)
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
