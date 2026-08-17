import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit
import WatchtowerTestSupport
import WatchtowerCore

/// Hub ingest of phone `recording_upload` records: asset file → `rec_*.m4a`
/// + `.meta` sidecar in the recordings directory → `received` ack, with the
/// existing recovery scan able to pick the file up. Failure paths write a
/// `failed` ack and leave the phone's copy authoritative.
final class RelayProcessorRecordingUploadTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var transport: InMemoryCloudTransport!
    private var processor: RelayProcessor!
    private var recordingsDir: URL!
    private var assetsDir: URL!
    private var ingested: OSAllocatedUnfairLock<[(URL, String?)]>!
    /// Injected clock (frozen wire-style constant, never wall clock).
    private let fixedNow = Date(timeIntervalSince1970: 1_782_009_600)

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-recupload-tests-\(UUID().uuidString)", isDirectory: true)
        recordingsDir = base.appendingPathComponent("recordings", isDirectory: true)
        assetsDir = base.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let hook = OSAllocatedUnfairLock<[(URL, String?)]>(initialState: [])
        ingested = hook
        processor = RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: MockClaudeService(),
            recordingsDirectory: recordingsDir,
            onRecordingIngested: { url, title in hook.withLock { $0.append((url, title)) } },
            now: { [fixedNow] in fixedNow }
        )
    }

    override func tearDownWithError() throws {
        processor = nil
        transport = nil
        sidecar = nil
        dbPool = nil
        try? FileManager.default.removeItem(at: recordingsDir.deletingLastPathComponent())
        TestDatabase.cleanup(path: dbPath)
    }

    // MARK: - Helpers

    private func makeAssetFile(name: String = "staged.m4a", bytes: Int = 128) throws -> URL {
        let url = assetsDir.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        return url
    }

    /// Saves a pending recording_upload record, as the phone would.
    @discardableResult
    private func enqueueUpload(
        id: String,
        titleHint: String? = nil,
        assetURL: URL?
    ) async throws -> String {
        let payload = RecordingUploadPayload(
            id: id,
            startedAt: fixedNow.addingTimeInterval(-600),
            endedAt: fixedNow.addingTimeInterval(-300),
            durationSec: 300,
            titleHint: titleHint,
            sampleFormat: "aac-64k-mono"
        )
        let record = try CloudRecordFactory.record(for: payload, modifiedAt: fixedNow, assetFileURL: assetURL)
        try await transport.save([record])
        return payload.recordName
    }

    private func ackPayload(recordName: String) async throws -> RecordingUploadPayload? {
        let batch = try await transport.changes(in: .relay, since: nil)
        guard let record = batch.changed.first(where: { $0.recordName == recordName }) else { return nil }
        return try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
    }

    private func recordingsDirContents() throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path))?.sorted() ?? []
    }

    // MARK: - Ingest

    func testPendingUploadLandsFileSidecarAndReceivedAck() async throws {
        let asset = try makeAssetFile()
        let recordName = try await enqueueUpload(id: "R1", titleHint: "Standup", assetURL: asset)

        _ = try await processor.processOnce()

        // File + sidecar in the recordings directory, rec_* m4a family.
        let contents = try recordingsDirContents()
        let audioName = try XCTUnwrap(contents.first { $0.hasPrefix("rec_") && $0.hasSuffix(".m4a") })
        XCTAssertTrue(contents.contains { $0.hasSuffix(".meta") })
        let audioURL = recordingsDir.appendingPathComponent(audioName)
        XCTAssertEqual(try Data(contentsOf: audioURL), Data(repeating: 0xCD, count: 128))

        // Sidecar mirrors the recovery format exactly: eventID null, title set.
        let metaURL = audioURL.deletingPathExtension().appendingPathExtension("meta")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any]
        XCTAssertEqual(meta?["title"] as? String, "Standup")
        XCTAssertTrue(meta?["eventID"] == nil || meta?["eventID"] is NSNull)

        // The write-back: received, no asset (the rewrite frees iCloud).
        let ack = try await ackPayload(recordName: recordName)
        XCTAssertEqual(ack?.status, .received)
        XCTAssertNil(ack?.errorMessage)
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertNil(batch.changed.first { $0.recordName == recordName }?.assetFileURL)

        // Hook fired with the landed file; the consumed staged asset is gone.
        let fired = ingested.withLock { $0 }
        XCTAssertEqual(fired.map(\.0), [audioURL])
        XCTAssertEqual(fired.map(\.1), ["Standup"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
    }

    @MainActor
    func testRecoveryScanPicksUpIngestedRecording() async throws {
        let asset = try makeAssetFile()
        try await enqueueUpload(id: "R2", titleHint: "Phone memo", assetURL: asset)
        _ = try await processor.processOnce()

        // A relaunch with the job never run: the normal recovery path must
        // surface the ingested file (this is the plan's "recovery picks it
        // up" gate — .m4a joined the scan family). Isolated defaults: the
        // legacy-pointer migration must not read (or clear) the dev
        // machine's real single-slot keys.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "recupload.tests.\(UUID().uuidString)"))
        let center = MeetingRecorderCenter(defaults: defaults, recordingsDirectory: recordingsDir)
        center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.count, 1)
        XCTAssertEqual(center.recoverable.first?.title, "Phone memo")
        XCTAssertNil(center.recoverable.first?.eventID)
        XCTAssertEqual(center.recoverable.first?.audioURL.pathExtension, "m4a")
    }

    // MARK: - Failure paths

    func testMissingAssetWritesFailedAck() async throws {
        let recordName = try await enqueueUpload(id: "R3", assetURL: nil)

        _ = try await processor.processOnce()

        let ack = try await ackPayload(recordName: recordName)
        XCTAssertEqual(ack?.status, .failed)
        XCTAssertEqual(ack?.errorMessage, "recording asset is missing")
        XCTAssertTrue(try recordingsDirContents().isEmpty)
        XCTAssertTrue(ingested.withLock { $0 }.isEmpty)
    }

    func testEmptyAssetWritesFailedAck() async throws {
        let asset = try makeAssetFile(name: "empty.m4a", bytes: 0)
        let recordName = try await enqueueUpload(id: "R4", assetURL: asset)

        _ = try await processor.processOnce()

        let ack = try await ackPayload(recordName: recordName)
        XCTAssertEqual(ack?.status, .failed)
        XCTAssertEqual(ack?.errorMessage, "recording asset is empty")
        XCTAssertTrue(try recordingsDirContents().isEmpty)
        // The failed staged file is NOT consumed — the phone's copy is
        // authoritative and a later re-upload restages it anyway.
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
    }

    // MARK: - Duplicates & echoes

    func testDuplicateDeliveryIsAbsorbedByProcessedSet() async throws {
        let asset = try makeAssetFile()
        try await enqueueUpload(id: "R5", assetURL: asset)
        _ = try await processor.processOnce()
        XCTAssertEqual(try recordingsDirContents().filter { $0.hasSuffix(".m4a") }.count, 1)

        // Redelivery of the same pending record (fresh staged file).
        let again = try makeAssetFile(name: "staged-2.m4a")
        try await enqueueUpload(id: "R5", assetURL: again)
        _ = try await processor.processOnce()

        XCTAssertEqual(try recordingsDirContents().filter { $0.hasSuffix(".m4a") }.count, 1)
        XCTAssertEqual(ingested.withLock { $0 }.count, 1)
    }

    func testOwnWriteBackEchoIsSkipped() async throws {
        var payload = RecordingUploadPayload(
            id: "R6",
            startedAt: fixedNow.addingTimeInterval(-600),
            endedAt: fixedNow.addingTimeInterval(-300),
            durationSec: 300,
            titleHint: nil,
            sampleFormat: "aac-64k-mono"
        )
        payload.status = .received
        try await transport.save([
            try CloudRecordFactory.record(for: payload, modifiedAt: fixedNow, assetFileURL: nil)
        ])

        _ = try await processor.processOnce()

        XCTAssertTrue(try recordingsDirContents().isEmpty)
        XCTAssertTrue(ingested.withLock { $0 }.isEmpty)
    }

    // MARK: - Hygiene

    func testHygieneDeletesAgedWriteBacksButKeepsUnprocessedPending() async throws {
        let staleDate = fixedNow.addingTimeInterval(-8 * 86_400)
        func payload(_ id: String, status: RecordingUploadStatus) -> RecordingUploadPayload {
            var upload = RecordingUploadPayload(
                id: id,
                startedAt: staleDate,
                endedAt: staleDate.addingTimeInterval(60),
                durationSec: 60,
                titleHint: nil,
                sampleFormat: "aac-64k-mono"
            )
            upload.status = status
            return upload
        }
        // An aged received write-back (our own) is purged by age alone; an
        // aged STILL-PENDING never-processed upload must survive for
        // processOnce — mobile is still waiting on its ack.
        try await transport.save([
            try CloudRecordFactory.record(for: payload("OLD", status: .received), modifiedAt: staleDate, assetFileURL: nil),
            try CloudRecordFactory.record(for: payload("WAIT", status: .pending), modifiedAt: staleDate, assetFileURL: nil)
        ])

        try await processor.runHygieneIfDue()

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.deletedRecordNames.contains("recupload-OLD"))
        XCTAssertTrue(batch.changed.map(\.recordName).contains("recupload-WAIT"))
    }
}
