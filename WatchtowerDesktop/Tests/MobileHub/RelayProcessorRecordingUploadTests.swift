import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// Hub ingest of phone `recording_upload` records (mobile POC spec §5.3,
/// §6.4): the asset lands as `rec_*.m4a` + `.meta` through the transcriber's
/// own phone-ingest helpers, the record is rewritten `received` without its
/// asset, and every failure is a `failed` echo that leaves the phone its file
/// and a working Retry. Review focus 3 (unwritable recordings dir) and 4 (the
/// event deleted after recording) live here.
@MainActor
final class RelayProcessorRecordingUploadTests: XCTestCase {
    private var transport: StubHubTransport!
    private var sidecar: HubSyncState!
    private var dbPool: DatabasePool!
    private var dbPath: String!
    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-recupload-\(UUID().uuidString)", isDirectory: true)
    private var recordingsDir: URL { base.appendingPathComponent("recordings", isDirectory: true) }
    private var assetsDir: URL { base.appendingPathComponent("assets", isDirectory: true) }
    /// Every enqueue the tracker asked the transcriber for.
    private var enqueued: [(audio: URL, eventID: String?, title: String?)] = []
    private var jobs: PhoneRecordingJobs!
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    override func setUp() async throws {
        transport = StubHubTransport()
        sidecar = try HubSyncState.inMemory()
        (dbPool, dbPath) = try TestDatabase.createPool()
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        enqueued = []
        jobs = try makeJobs()
    }

    override func tearDown() async throws {
        // A test may have locked a directory or a file down.
        for url in [recordingsDir, assetsDir] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: base)
        jobs = nil
        transport = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    /// The tracker over the transcriber's real phone-ingest file helpers
    /// (`reservePhoneRecording` + `copyPhoneRecording`, the steps
    /// `ingestPhoneRecording` runs before it enqueues the job).
    private func makeJobs() throws -> PhoneRecordingJobs {
        let dir = recordingsDir
        return try PhoneRecordingJobs(
            sidecar: sidecar, dbPool: dbPool, events: nil, now: { [now] in now },
            enqueue: { [weak self] audio, eventID, title in
                let url = try MeetingRecorderCenter.reservePhoneRecording(eventID: eventID, title: title, in: dir)
                try MeetingRecorderCenter.copyPhoneRecording(from: audio, to: url)
                self?.enqueued.append((url, eventID, title))
                return url
            }
        )
    }

    private func makeProcessor(
        ingest: Bool = true,
        isDeviceLinked: @escaping @Sendable (String) -> Bool = { !$0.isEmpty },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) throws -> RelayProcessor {
        let jobs = try XCTUnwrap(self.jobs)
        let uploads = RelayProcessor.RecordingUploads(
            ingest: { upload, audio in try await jobs.ingest(upload, audio: audio) },
            isDeviceLinked: isDeviceLinked,
            sleep: sleep
        )
        return RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme",
            recordingUploads: ingest ? uploads : nil
        ) { [now] in now }
    }

    private func makeAsset(_ name: String = "staged.m4a", bytes: Int = 128) throws -> URL {
        let url = assetsDir.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        return url
    }

    private func uploadPayload(
        id: String = "R1",
        title: String? = "Acme standup",
        eventID: String? = nil,
        deviceID: String? = "device-a"
    ) -> RecordingUploadPayload {
        RecordingUploadPayload(
            id: id, startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-300),
            durationSec: 300, titleHint: title, sampleFormat: "aac-64k-mono", eventID: eventID, deviceID: deviceID
        )
    }

    /// Saves a pending upload as the phone does; returns its record.
    @discardableResult
    private func send(_ upload: RecordingUploadPayload, asset: URL?) async throws -> CloudRecord {
        let record = try CloudRecordFactory.record(for: upload, modifiedAt: now, assetFileURL: asset)
        try await transport.save([record])
        return record
    }

    /// Every echo the hub wrote for `recordName`, in order.
    private func echoes(of recordName: String) throws -> [(payload: RecordingUploadPayload, record: CloudRecord)] {
        try transport.saved
            .map(\.record)
            .filter { $0.recordName == recordName }
            .map { (try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: $0.payload), $0) }
            .filter { $0.payload.status != .pending }
    }

    private func recordingFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []).filter { $0.hasPrefix("rec_") }.sorted()
    }

    // MARK: - Ack

    func testValidUploadWritesM4AAndMetaThenEchoesReceivedWithoutTheAsset() async throws {
        let asset = try makeAsset()
        let record = try await send(uploadPayload(), asset: asset)

        let pass = try await makeProcessor().processOnce()

        XCTAssertEqual(pass.handled, 1)
        let files = recordingFiles()
        XCTAssertEqual(files.count, 2, "one .m4a and its .meta: \(files)")
        let audioName = try XCTUnwrap(files.first { $0.hasSuffix(".m4a") })
        let audio = recordingsDir.appendingPathComponent(audioName)
        XCTAssertEqual(try Data(contentsOf: audio), Data(repeating: 0xCD, count: 128))
        let meta = try SliceJSON.object(try Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("meta")))
        XCTAssertEqual(meta["title"] as? String, "Acme standup")
        XCTAssertEqual(enqueued.map(\.audio), [audio], "the recording is enqueued for transcription")

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .received)
        XCTAssertNil(echo.payload.errorMessage)
        XCTAssertNil(echo.record.assetFileURL, "the rewrite drops the asset, which frees the iCloud storage")
        XCTAssertEqual(echo.payload.eventID, nil)
        XCTAssertEqual(echo.payload.deviceID, "device-a", "the echo keeps the phone's fields")
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "received")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path), "the transport's copy is consumed")

        let job = try XCTUnwrap(try sidecar.phoneRecordings().first)
        XCTAssertEqual(job.uploadID, "R1")
        XCTAssertEqual(job.audioPath, audio.path)
        XCTAssertEqual(job.status, .queued, "queued once the ingest returned")
    }

    // MARK: - Duplicate

    func testDuplicateDeliveryAfterReceivedIngestsNothingAndEchoesReceivedAgain() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset())
        let processor = try makeProcessor()
        _ = try await processor.processOnce()

        // The phone re-saved `pending` (with its asset) before it fetched
        // the hub's `received`, and its save won.
        let again = try CloudRecordFactory.record(for: uploadPayload(), modifiedAt: now, assetFileURL: try makeAsset("again.m4a"))
        try await transport.save([again])
        _ = try await processor.processOnce()
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(enqueued.count, 1, "a received upload is ingested once")
        XCTAssertEqual(recordingFiles().count, 2)
        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.map(\.payload.status), [.received, .received], "the stale pending converges to received")
        XCTAssertNil(echoes.last?.record.assetFileURL, "the re-echo drops the asset again")
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "received")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(again.assetFileURL).path),
            "the re-fetched copy is deleted after the re-echo, never left in the stash"
        )
    }

    func testAFailedReEchoKeepsTheReFetchedCopyUntilTheNextPass() async throws {
        try await send(uploadPayload(), asset: try makeAsset())
        let processor = try makeProcessor()
        _ = try await processor.processOnce()
        let again = try CloudRecordFactory.record(for: uploadPayload(), modifiedAt: now, assetFileURL: try makeAsset("again.m4a"))
        try await transport.save([again])
        let copy = try XCTUnwrap(again.assetFileURL)

        transport.failNextSaves(1)
        do {
            _ = try await processor.processOnce()
            XCTFail("the echo's save failed, so the pass fails")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "kept while the echo is unsaved")

        _ = try await processor.processOnce()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the retried re-echo removes it")
        XCTAssertEqual(enqueued.count, 1)
    }

    // MARK: - Missing asset

    func testMissingAssetFailsAndThePhoneKeepsItsFile() async throws {
        let record = try await send(uploadPayload(), asset: nil)

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .failed, "not `received`, so the phone keeps its file")
        XCTAssertFalse(echo.payload.errorMessage?.isEmpty ?? true, "the phone shows why")
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:not_found")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
        XCTAssertTrue(try sidecar.phoneRecordings().isEmpty, "no job for an upload that was not ingested")
    }

    func testAnEmptyAssetFails() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset(bytes: 0))

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:not_found")
        XCTAssertTrue(enqueued.isEmpty)
    }

    func testAFailedUploadIsIngestedWhenThePhoneSendsItAgain() async throws {
        let record = try await send(uploadPayload(), asset: nil)
        let processor = try makeProcessor()
        _ = try await processor.processOnce()

        // Retry on the phone re-sends the same record name, pending, with
        // its file.
        try await send(uploadPayload(), asset: try makeAsset())
        _ = try await processor.processOnce()

        XCTAssertEqual(try echoes(of: record.recordName).map(\.payload.status), [.failed, .received])
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "received")
    }

    // MARK: - Data-zone reset (final-review P2-I1)

    /// The CloudKit buffer never holds the hub's own saves, so after a pass
    /// the latest buffered event of each upload is still the phone's
    /// `pending` write. Hub saves land in `echoes`, reads see the phone only.
    private actor PhoneOnlyBuffer: CloudSyncTransport {
        let phone = InMemoryCloudTransport()
        private(set) var echoes: [CloudRecord] = []
        func save(_ records: [CloudRecord]) async throws { echoes += records }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {}
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            try await phone.changes(in: zone, since: token)
        }
    }

    /// After a DataZone-only reset the relay cursor stays, so a failed
    /// upload the phone never retried is not ingested behind its back and a
    /// received one is not re-echoed.
    func testADataZoneResetNeitherReingestsAFailedUploadNorReEchoesAReceivedOne() async throws {
        let buffer = PhoneOnlyBuffer()
        let jobs = try XCTUnwrap(self.jobs)
        let sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        func processor(linked: @escaping @Sendable (String) -> Bool) -> RelayProcessor {
            let uploads = RelayProcessor.RecordingUploads(
                ingest: { upload, audio in try await jobs.ingest(upload, audio: audio) },
                isDeviceLinked: linked,
                sleep: sleep
            )
            return RelayProcessor(
                transport: buffer, sidecar: sidecar, dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme",
                recordingUploads: uploads
            ) { [now] in now }
        }
        let failed = try CloudRecordFactory.record(
            for: uploadPayload(id: "R1", deviceID: "device-x"), modifiedAt: now, assetFileURL: try makeAsset("r1.m4a")
        )
        let received = try CloudRecordFactory.record(
            for: uploadPayload(id: "R2"), modifiedAt: now, assetFileURL: try makeAsset("r2.m4a")
        )
        try await buffer.phone.save([failed, received])
        _ = try await processor { $0 == "device-a" }.processOnce()
        XCTAssertEqual(try sidecar.relayOutcome(failed.recordName), "failed:device_not_linked")
        XCTAssertEqual(try sidecar.relayOutcome(received.recordName), "received")
        let echoCount = await buffer.echoes.count

        try sidecar.wipeSyncState(now: now, keepingRelayToken: true)
        _ = try await processor { !$0.isEmpty }.processOnce()

        XCTAssertEqual(enqueued.count, 1, "the failed upload is not ingested without a phone retry")
        let echoesAfter = await buffer.echoes.count
        XCTAssertEqual(echoesAfter, echoCount, "the received upload is not re-echoed")
        XCTAssertEqual(try sidecar.relayOutcome(failed.recordName), "failed:device_not_linked")
    }

    // MARK: - Review focus 3: the Mac cannot write the recording

    func testUnwritableRecordingsDirFailsWriteFailedAndLeavesNoPartialFile() async throws {
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recordingsDir.path)
        let asset = try makeAsset()
        let record = try await send(uploadPayload(), asset: asset)

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .failed, "the phone keeps its file and offers Retry")
        XCTAssertFalse(echo.payload.errorMessage?.isEmpty ?? true)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:write_failed")
        XCTAssertTrue(recordingFiles().isEmpty, "no half-written .m4a or .meta")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path), "the received copy is kept until an ingest succeeds")
    }

    func testACopyThatFailsMidwayLeavesNeitherAudioNorSidecar() async throws {
        // The reservation succeeds; the copy cannot read the source.
        let asset = try makeAsset()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: asset.path)
        let record = try await send(uploadPayload(), asset: asset)

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:write_failed")
        XCTAssertTrue(recordingFiles().isEmpty, "the reserved .meta is removed with the partial audio")
    }

    // MARK: - Review focus 4: the event is gone

    func testAnUploadForADeletedEventIsIngestedAdHoc() async throws {
        let record = try await send(uploadPayload(eventID: "evt-gone"), asset: try makeAsset())

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .received, "never failed")
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertNil(enqueued.first?.eventID, "the transcript is saved ad-hoc")
        let audio = try XCTUnwrap(enqueued.first?.audio)
        let meta = try SliceJSON.object(try Data(contentsOf: audio.deletingPathExtension().appendingPathExtension("meta")))
        XCTAssertTrue(meta["eventID"] == nil || meta["eventID"] is NSNull)
    }

    func testAnUploadForAnExistingEventIsLinkedToIt() async throws {
        try await dbPool.write { try TestDatabase.insertCalendarEvent($0, id: "evt-1") }
        try await send(uploadPayload(eventID: "evt-1"), asset: try makeAsset())

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(enqueued.map(\.eventID), ["evt-1"])
    }

    // MARK: - Device gate

    func testAnUploadFromAnUnlinkedDeviceFailsDeviceNotLinkedAndWritesNothing() async throws {
        let asset = try makeAsset()
        let record = try await send(uploadPayload(deviceID: "device-x"), asset: asset)

        _ = try await makeProcessor { $0 == "device-a" }.processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:device_not_linked")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
        XCTAssertTrue(try sidecar.phoneRecordings().isEmpty)
    }

    func testAnUploadWithoutADeviceIDFailsDeviceNotLinked() async throws {
        let record = try await send(uploadPayload(deviceID: nil), asset: try makeAsset())

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:device_not_linked")
        XCTAssertTrue(enqueued.isEmpty)
    }

    // MARK: - Exactly-once

    func testAnUploadFoundBegunAtStartIsNotIngestedAgainButARetryIs() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset())
        // The previous run stopped between the claim and the echo.
        try sidecar.markRelayBegun(record.recordName, at: now)
        let processor = try makeProcessor()

        _ = try await processor.processOnce()

        XCTAssertTrue(enqueued.isEmpty, "a `begun` upload is never re-applied by the hub itself")
        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:outcome_unknown")

        try await send(uploadPayload(), asset: try makeAsset("retry.m4a"))
        _ = try await processor.processOnce()
        XCTAssertEqual(enqueued.count, 1, "the phone's Retry is ingested (the accepted duplicate edge)")
    }

    func testAnIngestThatOutlivesItsTimeoutFailsOutcomeUnknown() async throws {
        let parked = Parked()
        defer { parked.release() }
        jobs = try PhoneRecordingJobs(
            sidecar: sidecar, dbPool: dbPool, events: nil, now: { [now] in now },
            enqueue: { _, _, _ in try await parked.wait() }
        )
        let record = try await send(uploadPayload(), asset: try makeAsset())

        // The deadline passes at once.
        _ = try await makeProcessor(sleep: { _ in }).processOnce() // swiftlint:disable:this trailing_closure

        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:outcome_unknown")
    }

    func testAHubWithoutAnIngestLeavesUploadsPending() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset())

        let pass = try await makeProcessor(ingest: false).processOnce()

        XCTAssertEqual(pass.handled, 0)
        XCTAssertTrue(try echoes(of: record.recordName).isEmpty)
        XCTAssertNil(try sidecar.relayPhase(record.recordName))
    }

    func testAnUndecodableUploadIsSkipped() async throws {
        let record = CloudRecord(
            recordName: "recupload-bad", zone: .relay, kind: RelayRecordKind.recordingUpload.rawValue,
            modifiedAt: now, payload: Data("{}".utf8)
        )
        try await transport.save([record])

        let pass = try await makeProcessor().processOnce()

        XCTAssertEqual(pass.handled, 0)
        XCTAssertTrue(enqueued.isEmpty)
    }
}

/// An ingest that never returns until the test releases it.
@MainActor
private final class Parked {
    private var continuation: CheckedContinuation<URL, Error>?

    func wait() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
