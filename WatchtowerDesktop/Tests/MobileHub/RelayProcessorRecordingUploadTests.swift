import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerE2ETesting
import WatchtowerSync
import WatchtowerTestSupport

/// Hub ingest of phone `recording_upload` records (mobile POC spec §5.3,
/// §6.4): the asset lands as `rec_*.m4a` + `.meta` through the transcriber's
/// own phone-ingest helpers, the record is rewritten `received` without its
/// asset, and every failure is a `failed` echo that leaves the phone its file
/// and a working Retry. Review focus 3 (unwritable recordings dir) and 4 (the
/// event deleted after recording) live here. Uploads are sealed by a
/// `TestE2E` phone and their audio by the chunked cipher (mobile E2E spec
/// §2.5): the hub decrypts to a temporary file, ingests it and removes it.
@MainActor
final class RelayProcessorRecordingUploadTests: XCTestCase {
    /// The stashed sealed audio of an upload, as CloudKit hands it over, and the descriptor its frame carries.
    private struct StagedAsset {
        let sealed: URL
        let descriptor: AssetDescriptor
        var path: String { sealed.path }
    }

    /// A phone the hub holds keys for but the sidecar has not linked (until a test links it).
    private let strangerID = TestE2E.strangerDeviceID.uuidString
    private var hubKeys: TestHubKeyProvider!
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
        hubKeys = TestE2E.hub()
        hubKeys.link(TestE2E.strangerIdentity)
        sidecar = try HubSyncState.inMemory()
        try sidecar.linkTestDevice()
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
        hubKeys = nil
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
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        clock: (@Sendable () -> Date)? = nil,
        maxSealedBytes: Int64 = RecordingUploader.maximumSealedAssetBytes,
        beforeIngest: (@MainActor @Sendable (URL) throws -> Void)? = nil
    ) throws -> RelayProcessor {
        let fixed = now
        let current = clock ?? { fixed }
        let jobs = try XCTUnwrap(self.jobs)
        let uploads = RelayProcessor.RecordingUploads(
            ingest: { upload, audio in
                try beforeIngest?(audio)
                try await jobs.ingest(upload, audio: audio)
            },
            sleep: sleep,
            maxSealedBytes: maxSealedBytes
        )
        return RelayProcessor(
            transport: testSecureTransport(transport, keys: hubKeys), sidecar: sidecar,
            dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme", recordingUploads: ingest ? uploads : nil,
            now: current
        )
    }

    /// The audio the phone recorded.
    private static func audio(bytes: Int) -> Data { Data(repeating: 0xCD, count: bytes) }

    /// The phone's audio sealed with a fresh `K_asset` into the transport's stash (`assetsDir/<name>`); no
    /// plaintext copy is left behind.
    private func makeAsset(_ name: String = "staged.m4a", bytes: Int = 128) throws -> StagedAsset {
        let plain = base.appendingPathComponent("plain-\(UUID().uuidString)")
        try Self.audio(bytes: bytes).write(to: plain)
        defer { try? FileManager.default.removeItem(at: plain) }
        let sealed = assetsDir.appendingPathComponent(name)
        let descriptor = try ChunkedAssetCipher.encryptFile(at: plain, to: sealed)
        return StagedAsset(sealed: sealed, descriptor: descriptor)
    }

    /// A pending upload as `identity`'s phone saves it: the record sealed `.relayToHub`, the descriptor in its
    /// frame, the sealed audio as its asset.
    private func sealedUpload(
        _ upload: RecordingUploadPayload, asset: StagedAsset?, as identity: DeviceIdentityKeys = TestE2E.deviceIdentity
    ) throws -> CloudRecord {
        let plain = try CloudRecordFactory.record(for: upload, modifiedAt: now, assetFileURL: asset?.sealed)
        return try TestRelayPhone.seal(
            CloudRecord(
                recordName: plain.recordName, zone: plain.zone, kind: plain.kind, modifiedAt: plain.modifiedAt,
                payload: plain.payload, assetFileURL: plain.assetFileURL, asset: asset?.descriptor),
            as: identity)
    }

    private func uploadPayload(
        id: String = "R1",
        title: String? = "Acme standup",
        eventID: String? = nil,
        deviceID: String? = testPhoneID,
        hubID: String? = nil
    ) -> RecordingUploadPayload {
        RecordingUploadPayload(
            id: id, startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-300),
            durationSec: 300, titleHint: title, sampleFormat: "aac-64k-mono", eventID: eventID, deviceID: deviceID,
            hubID: hubID
        )
    }

    /// Saves a pending upload as the phone does; returns its sealed record.
    @discardableResult
    private func send(
        _ upload: RecordingUploadPayload, asset: StagedAsset?, as identity: DeviceIdentityKeys = TestE2E.deviceIdentity
    ) async throws -> CloudRecord {
        let record = try sealedUpload(upload, asset: asset, as: identity)
        try await transport.save([record])
        return record
    }

    /// Every echo the hub wrote for the wire record `recordName`, in order, opened by the paired phone (`record`
    /// is the opened echo: its asset field is the wire record's).
    private func echoes(
        of recordName: String, as identity: DeviceIdentityKeys = TestE2E.deviceIdentity
    ) throws -> [(payload: RecordingUploadPayload, record: CloudRecord)] {
        try transport.openedEchoes(as: identity)
            .filter { $0.sealed?.wireName == recordName }
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
        XCTAssertEqual(echo.payload.deviceID, testPhoneID, "the echo keeps the phone's fields")
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
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
        let again = try sealedUpload(uploadPayload(), asset: try makeAsset("again.m4a"))
        try await transport.save([again])
        _ = try await processor.processOnce()
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(enqueued.count, 1, "a received upload is ingested once")
        XCTAssertEqual(recordingFiles().count, 2)
        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.map(\.payload.status), [.received, .received], "the stale pending converges to received")
        XCTAssertNil(echoes.last?.record.assetFileURL, "the re-echo drops the asset again")
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(again.assetFileURL).path),
            "the re-fetched copy is deleted after the re-echo, never left in the stash"
        )
    }

    func testAFailedReEchoKeepsTheReFetchedCopyUntilTheNextPass() async throws {
        try await send(uploadPayload(), asset: try makeAsset())
        let processor = try makeProcessor()
        _ = try await processor.processOnce()
        let again = try sealedUpload(uploadPayload(), asset: try makeAsset("again.m4a"))
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

    // MARK: - Sealed uploads (mobile E2E spec §2.5, Review Focus 2)

    /// CloudKit's re-fetch of the same record: the identical envelope bytes, its asset stashed again under a new
    /// local path.
    private func refetched(_ record: CloudRecord, asset: StagedAsset, as name: String) throws -> CloudRecord {
        let copy = assetsDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: asset.sealed, to: copy)
        return CloudRecord(
            recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
            payload: record.payload, assetFileURL: copy, creatorUserRecordName: record.creatorUserRecordName)
    }

    /// Review Focus 2: the phone's relaunch retry re-sends the stored envelope byte for byte. The hub takes it
    /// as the record it already ingested (the ledger), never as a rollback and never as a second recording;
    /// the phone gets `received` again.
    func testARetriedUploadWithTheSameEnvelopeIsIngestedOnce() async throws {
        let asset = try makeAsset()
        let record = try sealedUpload(uploadPayload(), asset: asset)
        // Stashed now: the first ingest consumes the first copy.
        let retry = try refetched(record, asset: asset, as: "retry.bin")
        try await transport.save([record])
        let processor = try makeProcessor()
        _ = try await processor.processOnce()

        XCTAssertEqual(retry.payload, record.payload, "the identical envelope")
        try await transport.save([retry])
        _ = try await processor.processOnce()

        XCTAssertEqual(enqueued.count, 1, "ingested once")
        XCTAssertEqual(recordingFiles().count, 2, "one .m4a and its .meta")
        XCTAssertEqual(try echoes(of: record.recordName).map(\.payload.status), [.received, .received], "re-echoed received")
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(retry.assetFileURL).path), "the copy is consumed")
    }

    /// Task 9: Retry after a FAILED hub echo re-sends the identical envelope too; a failed attempt wrote
    /// nothing, so that one is ingested.
    func testARetryOfTheSameEnvelopeAfterAFailedIngestIsIngested() async throws {
        let asset = try makeAsset()
        // The first delivery's asset never reached the Mac's stash.
        let record = try sealedUpload(uploadPayload(), asset: asset)
        let withoutAsset = CloudRecord(
            recordName: record.recordName, zone: record.zone, kind: record.kind, modifiedAt: record.modifiedAt,
            payload: record.payload)
        try await transport.save([withoutAsset])
        let processor = try makeProcessor()
        _ = try await processor.processOnce()
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:not_found")

        try await transport.save([record])
        _ = try await processor.processOnce()

        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(try echoes(of: record.recordName).map(\.payload.status), [.failed, .received])
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
    }

    /// Uploads have no age window (Task 12 ruling): a received upload's ledger row outlives the 8-day window
    /// while the epoch it was sealed in is accepted, so its identical envelope replayed after that is re-echoed
    /// `received`, never ingested a second time.
    func testAReceivedUploadReplayedAfterTheLedgerWindowInTheSameEpochIsNotIngestedAgain() async throws {
        // The hub's current epoch began long before the upload (`hub_epochs` is all the pruning reads).
        try sidecar.writeKeys { db in
            try HubSyncState.insertEpoch(
                HubSyncState.StoredEpoch(
                    epoch: 1, sealedKeys: Data(count: 32), createdAt: now.addingTimeInterval(-30 * 86_400), firstSeq: 0,
                    retiredAt: nil),
                db)
        }
        let clock = OSAllocatedUnfairLock(initialState: now)
        let asset = try makeAsset()
        let record = try sealedUpload(uploadPayload(), asset: asset)
        let replay = try refetched(record, asset: asset, as: "replay.bin")
        try await transport.save([record])
        let readClock: @Sendable () -> Date = { clock.withLock { $0 } }
        let processor = try makeProcessor(clock: readClock)
        _ = try await processor.processOnce()
        XCTAssertEqual(enqueued.count, 1)

        clock.withLock { $0 = now.addingTimeInterval(RelayProcessor.actionMaxAge + 2 * 86_400) }
        try await processor.runHygieneIfDue()
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received", "kept while its epoch is accepted")

        try await transport.save([replay])
        _ = try await processor.processOnce()

        XCTAssertEqual(enqueued.count, 1, "never ingested a second time")
        XCTAssertEqual(try echoes(of: record.recordName).last?.payload.status, .received, "re-echoed received")
    }

    /// Final review Desktop M-1: the ledger row of an ingested upload is gone (pruned after a rotation's grace)
    /// when the phone re-sends it, re-sealed after a wipe that lost the echo. The hub still remembers the
    /// upload id (`phone_recordings`), so it echoes `received` and ingests nothing a second time.
    func testAnUploadIngestedBeforeItsLedgerRowWasPrunedIsNotIngestedAgain() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset())
        let processor = try makeProcessor()
        _ = try await processor.processOnce()
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(try sidecar.phoneRecordings().map(\.uploadID), ["R1"])

        // No `hub_epochs` row here: the prune goes by the cutoff alone.
        try sidecar.pruneRelayProcessed(olderThan: now.addingTimeInterval(86_400), now: now)
        XCTAssertNil(try sidecar.relayOutcome(record.plainName), "the ledger row is gone")
        try await send(uploadPayload(), asset: try makeAsset("resealed.m4a"))
        _ = try await processor.processOnce()

        XCTAssertEqual(enqueued.count, 1, "the upload id was ingested already")
        XCTAssertEqual(recordingFiles().count, 2, "one .m4a and its .meta")
        XCTAssertEqual(try echoes(of: record.recordName).map(\.payload.status), [.received, .received])
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
    }

    /// The ingest is handed the decrypted audio in a temporary file beside the stash; once the pass ends no
    /// plaintext copy is left, and the sealed stash of a received upload is consumed.
    func testTheIngestReceivesThePlainAudioAndNoPlainCopyIsLeft() async throws {
        let handed = OSAllocatedUnfairLock<[(url: URL, bytes: Data)]>(initialState: [])
        let asset = try makeAsset(bytes: 3 * 1024 * 1024 + 17)
        let record = try await send(uploadPayload(), asset: asset)

        let modes = OSAllocatedUnfairLock<[Int]>(initialState: [])
        _ = try await makeProcessor { audio in
            let bytes = try Data(contentsOf: audio)
            handed.withLock { $0.append((audio, bytes)) }
            let mode = try FileManager.default.attributesOfItem(atPath: audio.path)[.posixPermissions] as? NSNumber
            modes.withLock { $0.append(mode?.intValue ?? -1) }
        }.processOnce()

        XCTAssertEqual(modes.withLock { $0 }, [0o600], "the plaintext copy is owner-only")
        let seen = try XCTUnwrap(handed.withLock { $0 }.first)
        XCTAssertEqual(seen.bytes, Self.audio(bytes: 3 * 1024 * 1024 + 17), "the plain audio, not the ciphertext")
        XCTAssertEqual(seen.url.deletingLastPathComponent().standardizedFileURL, assetsDir.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seen.url.path), "the plaintext copy is removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assetsDir.path), [], "nothing left in the stash")
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
    }

    /// A sealed asset that does not open under the frame's key (a flipped bit, or restaged under another key)
    /// fails `not_found`: nothing is written and the phone's Retry stays possible.
    func testATamperedSealedAssetFailsNotFoundAndWritesNothing() async throws {
        let asset = try makeAsset()
        var sealed = try Data(contentsOf: asset.sealed)
        sealed[10] ^= 0x01
        try sealed.write(to: asset.sealed)
        let record = try await send(uploadPayload(), asset: asset)

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .failed)
        XCTAssertEqual(echo.payload.errorMessage, RelayProcessor.missingAudioMessage)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:not_found")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
        XCTAssertTrue(try sidecar.phoneRecordings().isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: assetsDir.path), [asset.sealed.lastPathComponent],
            "no plaintext left; the sealed copy is kept until an ingest succeeds")
    }

    /// A sealed asset over the phone's own cap is refused before it is decrypted (target 149): no plaintext, no
    /// ingest, and the phone is told why.
    func testAnOversizedSealedAssetIsRefusedUndecrypted() async throws {
        let asset = try makeAsset(bytes: 4_096)
        let record = try await send(uploadPayload(), asset: asset)

        _ = try await makeProcessor(maxSealedBytes: 1_024).processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .failed)
        XCTAssertEqual(echo.payload.errorMessage, RelayProcessor.tooLargeMessage)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:invalid_params")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: assetsDir.path), [asset.sealed.lastPathComponent],
            "nothing was decrypted beside the stash")
    }

    /// An upload whose payload names another record than its envelope is dropped (target 148).
    func testAnUploadWhosePayloadNamesAnotherRecordIsIgnored() async throws {
        let plain = try CloudRecordFactory.record(for: uploadPayload(id: "R2"), modifiedAt: now, assetFileURL: nil)
        let record = try TestRelayPhone.seal(CloudRecord(
            recordName: "recupload-R1", zone: plain.zone, kind: plain.kind, modifiedAt: plain.modifiedAt,
            payload: plain.payload))
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertTrue(try echoes(of: record.recordName).isEmpty)
        XCTAssertNil(try sidecar.relayPhase("recupload-R1"))
        XCTAssertNil(try sidecar.relayPhase("recupload-R2"))
        XCTAssertTrue(enqueued.isEmpty)
    }

    // MARK: - Missing asset

    func testMissingAssetFailsAndThePhoneKeepsItsFile() async throws {
        let record = try await send(uploadPayload(), asset: nil)

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.payload.status, .failed, "not `received`, so the phone keeps its file")
        XCTAssertFalse(echo.payload.errorMessage?.isEmpty ?? true, "the phone shows why")
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:not_found")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
        XCTAssertTrue(try sidecar.phoneRecordings().isEmpty, "no job for an upload that was not ingested")
    }

    func testAnEmptyAssetFails() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset(bytes: 0))

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:not_found")
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
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "received")
    }

    // MARK: - Data-zone reset (final-review P2-I1)

    /// A processor over `buffer` (`PhoneOnlyBuffer`: reads see the phone's
    /// saves only, the hub's land in `echoes`).
    private func processor(
        over buffer: PhoneOnlyBuffer
    ) throws -> RelayProcessor {
        let jobs = try XCTUnwrap(self.jobs)
        let sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        let uploads = RelayProcessor.RecordingUploads(
            ingest: { upload, audio in try await jobs.ingest(upload, audio: audio) },
            sleep: sleep
        )
        return RelayProcessor(
            transport: testSecureTransport(buffer, keys: hubKeys), sidecar: sidecar,
            dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme", recordingUploads: uploads
        ) { [now] in now }
    }

    /// CloudKit never buffers the hub's own echo, so a re-read of the relay
    /// (a reset rewinding the cursor, a pass that stopped short) still shows
    /// the phone's `pending` save: that stale copy is neither re-echoed nor
    /// re-ingested; only a later phone save is.
    func testAReReadOfTheHubsOwnStaleCopiesEchoesAndIngestsNothing() async throws {
        let buffer = PhoneOnlyBuffer()
        let failed = try sealedUpload(
            uploadPayload(id: "R1", deviceID: strangerID), asset: try makeAsset("r1.m4a"), as: TestE2E.strangerIdentity
        )
        let received = try sealedUpload(
            uploadPayload(id: "R2"), asset: try makeAsset("r2.m4a")
        )
        try await buffer.phone.save([failed, received])
        _ = try await processor(over: buffer).processOnce()
        let echoCount = await buffer.echoes.count
        XCTAssertEqual(echoCount, 2)
        try sidecar.linkTestDevice(strangerID)  // the phone links meanwhile

        try sidecar.wipeSyncState(now: now)  // an account reset: the relay is read from the start
        _ = try await processor(over: buffer).processOnce()

        let echoesAfter = await buffer.echoes.count
        XCTAssertEqual(echoesAfter, echoCount, "the hub's own stale copies are no phone change")
        XCTAssertEqual(enqueued.count, 1, "the failed upload is not ingested without a phone retry")

        // The phone's Retry is a later save: it is ingested.
        let retry = try sealedUpload(
            uploadPayload(id: "R1", deviceID: strangerID), asset: try makeAsset("r1-again.m4a"), as: TestE2E.strangerIdentity
        )
        try await buffer.phone.save([retry])
        _ = try await processor(over: buffer).processOnce()
        XCTAssertEqual(enqueued.count, 2)
    }

    /// After a DataZone-only reset the relay cursor stays, so a failed
    /// upload the phone never retried is not ingested behind its back and a
    /// received one is not re-echoed.
    func testADataZoneResetNeitherReingestsAFailedUploadNorReEchoesAReceivedOne() async throws {
        let buffer = PhoneOnlyBuffer()
        let jobs = try XCTUnwrap(self.jobs)
        let sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        func processor() -> RelayProcessor {
            let uploads = RelayProcessor.RecordingUploads(
                ingest: { upload, audio in try await jobs.ingest(upload, audio: audio) },
                sleep: sleep
            )
            return RelayProcessor(
                transport: testSecureTransport(buffer, keys: hubKeys), sidecar: sidecar,
                dispatcher: MobileHubCommandDispatcher(), hubID: "hub-acme", recordingUploads: uploads
            ) { [now] in now }
        }
        let failed = try sealedUpload(
            uploadPayload(id: "R1", deviceID: strangerID), asset: try makeAsset("r1.m4a"), as: TestE2E.strangerIdentity
        )
        let received = try sealedUpload(
            uploadPayload(id: "R2"), asset: try makeAsset("r2.m4a")
        )
        try await buffer.phone.save([failed, received])
        _ = try await processor().processOnce()
        XCTAssertEqual(try sidecar.relayOutcome(failed.plainName), "failed:device_not_linked")
        XCTAssertEqual(try sidecar.relayOutcome(received.plainName), "received")
        let echoCount = await buffer.echoes.count

        try sidecar.wipeSyncState(now: now, keepingRelayToken: true)
        try sidecar.linkTestDevice(strangerID)  // the phone links meanwhile
        _ = try await processor().processOnce()

        XCTAssertEqual(enqueued.count, 1, "the failed upload is not ingested without a phone retry")
        let echoesAfter = await buffer.echoes.count
        XCTAssertEqual(echoesAfter, echoCount, "the received upload is not re-echoed")
        XCTAssertEqual(try sidecar.relayOutcome(failed.plainName), "failed:device_not_linked")
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
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:write_failed")
        XCTAssertTrue(recordingFiles().isEmpty, "no half-written .m4a or .meta")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path), "the received copy is kept until an ingest succeeds")
    }

    func testACopyThatFailsMidwayLeavesNeitherAudioNorSidecar() async throws {
        // The reservation succeeds; the copy cannot read the source (the decrypted copy).
        let record = try await send(uploadPayload(), asset: try makeAsset())

        _ = try await makeProcessor { audio in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: audio.path)
        }.processOnce()

        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:write_failed")
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
        let record = try await send(uploadPayload(deviceID: strangerID), asset: asset, as: TestE2E.strangerIdentity)

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName, as: TestE2E.strangerIdentity).first)
        XCTAssertEqual(echo.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:device_not_linked")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
        XCTAssertTrue(try sidecar.phoneRecordings().isEmpty)
    }

    func testAnUploadWithoutADeviceIDFailsDeviceNotLinked() async throws {
        let record = try await send(uploadPayload(deviceID: nil), asset: try makeAsset())

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:device_not_linked")
        XCTAssertTrue(enqueued.isEmpty)
    }

    // MARK: - Exactly-once

    func testAnUploadFoundBegunAtStartIsNotIngestedAgainButARetryIs() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset())
        // The previous run stopped between the claim and the echo.
        try sidecar.markRelayBegun(record.plainName, at: now)
        let processor = try makeProcessor()

        _ = try await processor.processOnce()

        XCTAssertTrue(enqueued.isEmpty, "a `begun` upload is never re-applied by the hub itself")
        XCTAssertEqual(try echoes(of: record.recordName).first?.payload.status, .failed)
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:outcome_unknown")

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
        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:outcome_unknown")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: assetsDir.path), ["staged.m4a"],
            "the decrypted copy is gone after the timeout; only the sealed stash is kept")
    }

    func testAHubWithoutAnIngestLeavesUploadsPending() async throws {
        let record = try await send(uploadPayload(), asset: try makeAsset())

        let pass = try await makeProcessor(ingest: false).processOnce()

        XCTAssertEqual(pass.handled, 0)
        XCTAssertTrue(try echoes(of: record.recordName).isEmpty)
        XCTAssertNil(try sidecar.relayPhase(record.plainName))
    }

    func testAnUndecodableUploadIsSkipped() async throws {
        let record = try TestRelayPhone.seal(CloudRecord(
            recordName: "recupload-bad", zone: .relay, kind: RelayRecordKind.recordingUpload.rawValue,
            modifiedAt: now, payload: Data("{}".utf8)
        ))
        try await transport.save([record])

        let pass = try await makeProcessor().processOnce()

        XCTAssertEqual(pass.handled, 0)
        XCTAssertTrue(enqueued.isEmpty)
    }

    // MARK: - Hub addressing

    func testAnUploadForAnotherHubFailsWrongHubAndWritesNothing() async throws {
        let record = try await send(uploadPayload(hubID: "hub-other"), asset: try makeAsset())

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try sidecar.relayOutcome(record.plainName), "failed:wrong_hub")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
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
