import CryptoKit
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The phone upload state machine: waiting → uploading → delivered/failed,
/// including the degenerate branches (zero-length capture, retry after
/// relaunch, ack after local delete). Dates derive from Date() — no
/// hardcoded wall-clock values.
final class RecordingUploaderTests: XCTestCase {
    private static let deviceID = "device-a"
    private var dir: URL!
    /// The paired test phone's key store, shared by every transport and replica of one test.
    private var phoneKeys: InMemoryPhoneKeyStore!

    override func setUpWithError() throws {
        phoneKeys = try TestE2E.phoneStore()
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

    /// The paired phone's transport over `inner`: it seals what the uploader sends and opens its own records.
    private func phone(_ inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport()) throws -> SecureTransport {
        TestE2E.phoneTransport(try TestE2E.phone(store: phoneKeys), inner: inner)
    }

    private func makeStore() throws -> ReplicaStore {
        try ReplicaStore.inMemory(opener: TestE2E.opener(store: phoneKeys))
    }

    /// The opaque name an upload record travels under (what an inner transport sees).
    private func wire(_ id: String) throws -> String {
        try phone().wireName(plain: "recupload-\(id)", zone: .relay)
    }

    private func sealedFile(_ id: String, in folder: URL? = nil) -> URL {
        (folder ?? dir).appendingPathComponent("\(id).enc")
    }

    private func makeStack(
        transport inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport()
    ) throws -> (RecordingUploader, ReplicaStore, SecureTransport) {
        let store = try makeStore()
        let transport = try phone(inner)
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

        // The relay record carries the sealed asset and a pending payload.
        let sealed = sealedFile(recording.id)
        let batch = try await transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(batch.changed.first { $0.recordName == "recupload-\(recording.id)" })
        XCTAssertEqual(record.kind, "recording_upload")
        XCTAssertEqual(record.assetFileURL, sealed)
        XCTAssertNotNil(record.asset, "the asset descriptor rides inside the envelope")
        let payload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: record.payload)
        XCTAssertEqual(payload.status, .pending)
        XCTAssertEqual(payload.durationSec, 120)

        // Hub ack: received → delivered, and ONLY now both local copies go (ask #89 A: the plain audio stays
        // on the phone until the Mac confirms it).
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the plain audio waits for the Mac's receipt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealed.path))
        try await uploader.applyEcho(echo(for: recording, status: .received))
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealed.path))
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
        let transport = try phone()
        let store = try makeStore()
        let file = try makeAudioFile()

        let clock = TestClock()
        let first = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID) { clock.now }
        let recording = try await register(first, file: file, duration: 60)
        _ = try await first.uploadPending()

        // "Relaunch" once the first backoff step has passed: a fresh
        // uploader over the same store re-sends the still-uploading row
        // (the hub's processed-set absorbs duplicates).
        clock.advance(RecordingUploader.retryDelays[0])
        let second = RecordingUploader(transport: transport, store: store, deviceID: Self.deviceID) { clock.now }
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
        XCTAssertEqual(saves.filter { $0 == (try? self.wire(first.id)) }.count, 1)
        XCTAssertEqual(saves.filter { $0 == (try? self.wire(second.id)) }.count, 1)
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
        XCTAssertEqual(saves.filter { $0 == (try? self.wire(first.id)) }.count, 1)
        XCTAssertEqual(saves.filter { $0 == (try? self.wire(second.id)) }.count, 1)
    }

    /// The launch pass of a new process re-sends an `uploading` row once —
    /// the relaunch retry — and later passes leave it alone.
    func testTheLaunchPassResendsAnUploadingRowOnce() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let before = RecordingUploader(
            transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID
        ) { clock.now }
        let recording = try await register(before, file: try makeAudioFile())
        _ = try await before.uploadPending()
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)

        clock.advance(RecordingUploader.retryDelays[0])
        let spy = SpyTransport()
        let relaunched = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) { clock.now }
        let launch = try await relaunched.uploadPending()
        let later = try await relaunched.uploadPending()

        XCTAssertEqual(launch, 1)
        XCTAssertEqual(later, 0)
        let saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(recording.id)])
    }

    /// A launch pass that exits by throwing (a store write failing — the
    /// attempt count, before any save) keeps the in-flight re-send armed, so
    /// the next pass re-sends the `uploading` row instead of stranding it
    /// until the next launch (final-review P1-M1). The store's failure seam
    /// is an SQLite trigger.
    func testALaunchPassThatThrowsKeepsTheInFlightResendArmed() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let before = RecordingUploader(
            transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID
        ) { clock.now }
        let recording = try await register(before, file: try makeAudioFile())
        _ = try await before.uploadPending()
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)

        clock.advance(RecordingUploader.retryDelays[0])
        let spy = SpyTransport()
        let relaunched = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) { clock.now }
        try await store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_state BEFORE UPDATE ON phone_recordings
                BEGIN SELECT RAISE(ABORT, 'store write failed'); END
                """)
        }
        do {
            _ = try await relaunched.uploadPending()
            XCTFail("the state write fails, so the pass throws")
        } catch {}
        try await store.writer.write { db in try db.execute(sql: "DROP TRIGGER fail_state") }

        let retried = try await relaunched.uploadPending()

        XCTAssertEqual(retried, 1, "the uploading row is re-sent by the next pass")
        let saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(recording.id)], "the throwing pass failed before its save")
    }

    /// The launch pass waits for a link: a pass without a device sends
    /// nothing and does not use up the re-send of in-flight rows.
    func testTheLaunchResendWaitsForALinkedDevice() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let before = RecordingUploader(
            transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID
        ) { clock.now }
        let recording = try await register(before, file: try makeAudioFile())
        _ = try await before.uploadPending()

        clock.advance(RecordingUploader.retryDelays[0])
        let spy = SpyTransport()
        let relaunched = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: nil) { clock.now }
        _ = try await relaunched.uploadPending()
        await relaunched.setDeviceID(Self.deviceID)
        _ = try await relaunched.uploadPending()

        let saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(recording.id)])
    }

    /// While the Mac sleeps (its heartbeat is stale) the relaunch re-save of
    /// an `uploading` row waits: the row is already in CloudKit's queue, so
    /// nothing is saved and no attempt is counted toward "Upload stuck". The
    /// first foreground pass that finds the Mac online re-saves it.
    func testTheRelaunchResaveWaitsForTheMacOnline() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let before = RecordingUploader(
            transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID
        ) { clock.now }
        let recording = try await register(before, file: try makeAudioFile())
        _ = try await before.uploadPending()
        let saved = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(saved.uploadAttempts, 1)

        clock.advance(RecordingUploader.retryDelays[0])
        let online = OnlineFlag()
        let spy = SpyTransport()
        let relaunched = RecordingUploader(
            transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID,
            now: { clock.now }, macOnline: { online.value }
        )
        for _ in 0..<3 {
            let sent = try await relaunched.uploadPending()
            XCTAssertEqual(sent, 0, "no re-save while the Mac sleeps")
        }
        let waiting = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(waiting.state, .uploading)
        XCTAssertEqual(waiting.uploadAttempts, 1, "no attempt is counted")
        XCTAssertEqual(waiting.lastAttemptAt, saved.lastAttemptAt)
        let none = await spy.savedNames
        XCTAssertTrue(none.isEmpty)

        online.value = true
        let resent = try await relaunched.uploadPending()
        let later = try await relaunched.uploadPending()
        XCTAssertEqual(resent, 1, "the Mac is back: the relaunch re-save runs once")
        XCTAssertEqual(later, 0)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.uploadAttempts, 2)
    }

    /// A wipe emptied the queue: its re-send does not wait for the Mac.
    func testAWipeResendDoesNotWaitForTheMac() async throws {
        let spy = SpyTransport()
        let store = try makeStore()
        let asleep: @Sendable () -> Bool = { false }
        let uploader = RecordingUploader(
            transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID, macOnline: asleep
        )
        let recording = try await register(uploader, file: try makeAudioFile())
        _ = try await uploader.uploadPending()

        await uploader.resendInFlightAfterWipe()
        _ = try await uploader.uploadPending()

        let saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(recording.id), try wire(recording.id)])
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
        XCTAssertEqual(saves, [try wire(recording.id), try wire(recording.id)])
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
        // Sealed before the save: the sealed copy is the one kept for the next pass.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
        XCTAssertNotNil(try store.phoneRecording(id: recording.id)?.envelope)
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
        // The local (sealed) file survives a failed ingest — it is the only copy.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))

        try await uploader.retryFailed(id: recording.id)
        row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .uploading)
        XCTAssertNil(row.errorMessage)
    }

    // MARK: - Bounded retry (board #724)

    /// A box the tests flip to say whether the app is in the foreground.
    private final class Foreground: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isOn: Bool { lock.withLock { value } }
        func set(_ on: Bool) { lock.withLock { value = on } }
    }

    private func makeBounded(
        transport: any CloudSyncTransport & Sendable,
        store: ReplicaStore,
        clock: TestClock,
        foreground: Foreground = Foreground(true)
    ) throws -> RecordingUploader {
        RecordingUploader(
            transport: try phone(transport), store: store, directory: dir, deviceID: Self.deviceID,
            now: { clock.now }, retriesAllowed: { foreground.isOn }
        )
    }

    /// A save that keeps failing is retried 1 min, 5 min, 30 min, 2 h and
    /// 6 h after each attempt, never earlier, and stops at the sixth: the
    /// row then reads stuck and offers Retry.
    func testRetriesBackOffAndStopAtTheCap() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let spy = SpyTransport()
        await spy.setFailing(true)
        let uploader = try makeBounded(transport: spy, store: store, clock: clock)
        let recording = try await register(uploader, file: try makeAudioFile())
        let attempts = { try XCTUnwrap(try store.phoneRecording(id: recording.id)).uploadAttempts }

        _ = try await uploader.uploadPending()
        XCTAssertEqual(try attempts(), 1, "a new recording goes out at once")
        for (index, delay) in RecordingUploader.retryDelays.enumerated() {
            clock.advance(delay - 1)
            _ = try await uploader.uploadPending()
            XCTAssertEqual(try attempts(), index + 1, "not before \(Int(delay)) s")
            clock.advance(1)
            _ = try await uploader.uploadPending()
            XCTAssertEqual(try attempts(), index + 2, "due after \(Int(delay)) s")
        }
        XCTAssertEqual(try attempts(), PhoneRecording.uploadAttemptCap)

        clock.advance(7 * 86_400)
        _ = try await uploader.uploadPending()
        XCTAssertEqual(try attempts(), PhoneRecording.uploadAttemptCap, "no attempt past the cap")
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .waiting)
        XCTAssertTrue(row.isUploadStuck)
        XCTAssertTrue(row.offersRetry)
        let saves = await spy.savedNames
        XCTAssertEqual(saves.count, PhoneRecording.uploadAttemptCap)
    }

    /// The schedule itself: due at once before any attempt, each delay
    /// after the latest attempt, nil at the cap.
    func testNextAttemptSchedule() {
        let last = Date()
        XCTAssertEqual(RecordingUploader.nextAttemptAt(attempts: 0, last: nil), .distantPast)
        XCTAssertEqual(RecordingUploader.retryDelays, [60, 300, 1_800, 7_200, 21_600])
        for (index, delay) in RecordingUploader.retryDelays.enumerated() {
            XCTAssertEqual(RecordingUploader.nextAttemptAt(attempts: index + 1, last: last), last.addingTimeInterval(delay))
        }
        XCTAssertNil(RecordingUploader.nextAttemptAt(attempts: PhoneRecording.uploadAttemptCap, last: last))
    }

    /// A launch into the background (a silent push) re-sends nothing: an
    /// `uploading` row waits, however due, while a new recording still goes
    /// out. The first foreground pass then
    /// re-sends the due rows.
    func testABackgroundLaunchStartsNoReupload() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let before = try makeBounded(transport: InMemoryCloudTransport(), store: store, clock: clock)
        let inFlight = try await register(before, file: try makeAudioFile(name: "flight.m4a"))
        _ = try await before.uploadPending()
        clock.advance(3_600)

        let spy = SpyTransport()
        let foreground = Foreground(false)
        let relaunched = try makeBounded(transport: spy, store: store, clock: clock, foreground: foreground)
        let fresh = try await register(relaunched, file: try makeAudioFile(name: "fresh.m4a"))
        _ = try await relaunched.uploadPending()
        var saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(fresh.id)], "only the never-sent recording goes out in the background")
        XCTAssertEqual(try store.phoneRecording(id: inFlight.id)?.uploadAttempts, 1)

        foreground.set(true)
        _ = try await relaunched.uploadPending()
        saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(fresh.id), try wire(inFlight.id)], "the foreground pass re-sends")
        XCTAssertEqual(try store.phoneRecording(id: inFlight.id)?.uploadAttempts, 2)
    }

    /// A save that failed in the foreground is not retried by a background
    /// pass, even when due.
    func testABackgroundPassDoesNotRetryAFailedSave() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let spy = SpyTransport()
        await spy.setFailing(true)
        let foreground = Foreground(true)
        let uploader = try makeBounded(transport: spy, store: store, clock: clock, foreground: foreground)
        let recording = try await register(uploader, file: try makeAudioFile())
        _ = try await uploader.uploadPending()
        await spy.setFailing(false)
        foreground.set(false)
        clock.advance(3_600)

        _ = try await uploader.uploadPending()
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.uploadAttempts, 1)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .waiting)

        foreground.set(true)
        _ = try await uploader.uploadPending()
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)
    }

    /// The owner's Retry on a stuck upload resets the backoff and sends at
    /// once.
    func testManualRetryOfAStuckUploadResetsTheBackoff() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let spy = SpyTransport()
        await spy.setFailing(true)
        let uploader = try makeBounded(transport: spy, store: store, clock: clock)
        let recording = try await register(uploader, file: try makeAudioFile())
        _ = try await uploader.uploadPending()
        for delay in RecordingUploader.retryDelays {
            clock.advance(delay)
            _ = try await uploader.uploadPending()
        }
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.isUploadStuck, true)

        await spy.setFailing(false)
        try await uploader.retryFailed(id: recording.id)
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .uploading)
        XCTAssertEqual(row.uploadAttempts, 1, "the Retry starts a fresh backoff")
        XCTAssertFalse(row.isUploadStuck)
        XCTAssertFalse(row.offersRetry)
    }

    /// A `received` echo ends the retries: a delivered row is never sent
    /// again, at the next foreground launch or ever.
    func testAReceivedEchoEndsRetries() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let uploader = try makeBounded(transport: InMemoryCloudTransport(), store: store, clock: clock)
        let recording = try await register(uploader, file: try makeAudioFile())
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .received))

        clock.advance(86_400)
        let spy = SpyTransport()
        let relaunched = try makeBounded(transport: spy, store: store, clock: clock)
        let sent = try await relaunched.uploadPending()
        XCTAssertEqual(sent, 0)
        let saves = await spy.savedNames
        XCTAssertTrue(saves.isEmpty)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .delivered)
    }

    /// A stuck `uploading` row (the cap reached by relaunch re-sends) that
    /// the Mac finally acknowledges is delivered, not stuck.
    func testAStuckUploadThatIsAcknowledgedIsDelivered() async throws {
        let store = try makeStore()
        let clock = TestClock()
        let first = try makeBounded(transport: InMemoryCloudTransport(), store: store, clock: clock)
        let recording = try await register(first, file: try makeAudioFile())
        _ = try await first.uploadPending()
        for delay in RecordingUploader.retryDelays {
            clock.advance(delay)
            let relaunched = try makeBounded(transport: InMemoryCloudTransport(), store: store, clock: clock)
            _ = try await relaunched.uploadPending()
        }
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.isUploadStuck, true)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)

        try await first.applyEcho(echo(for: recording, status: .received))
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .delivered)
        XCTAssertFalse(row.isUploadStuck)
        XCTAssertFalse(row.offersRetry)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
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
        transport: SecureTransport
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
        let transport = try phone()
        let store = try makeStore()
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

    /// A blank device id is no link, the same rule as ActionOutbox: the
    /// upload waits locally instead of failing at the hub as
    /// `device_not_linked` (final-review P2-M5).
    func testABlankDeviceIDLeavesUploadsWaiting() async throws {
        let transport = try phone()
        let store = try makeStore()
        let viaInit = RecordingUploader(transport: transport, store: store, directory: dir, deviceID: "")
        let recording = try await register(viaInit, file: try makeAudioFile())
        let viaSetter = RecordingUploader(transport: transport, store: store, directory: dir, deviceID: Self.deviceID)
        await viaSetter.setDeviceID("  ")

        let sentViaInit = try await viaInit.uploadPending()
        let sentViaSetter = try await viaSetter.uploadPending()

        XCTAssertEqual(sentViaInit + sentViaSetter, 0)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .waiting)
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
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
        let transport = try phone()
        let store = try makeStore()
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
            transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID, maxAssetBytes: 1
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
    private func relaunched(_ store: ReplicaStore) throws -> RecordingUploader {
        RecordingUploader(transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID)
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
        XCTAssertEqual(Set(assets.map(\.lastPathComponent)), ["\(saved.id).enc", "\(stranded.id).enc"])
        XCTAssertEqual(Set(assets.map { $0.deletingLastPathComponent().standardizedFileURL }), [moved.standardizedFileURL])
        XCTAssertTrue(assets.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try store.phoneRecording(id: saved.id)?.state, .uploading)
    }

    /// A row written by an older build holds an absolute path into the old
    /// container. It is rewritten to the bare name and found in the new one.
    func testALegacyAbsolutePathIsMovedToTheCurrentFolder() async throws {
        let transport = try phone()
        let store = try makeStore()
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
        let transport = try phone()
        let store = try makeStore()
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
        let transport = try phone()
        let store = try makeStore()
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

    // MARK: - Sealing (mobile E2E: sealed at finalization, the same envelope re-sent)

    /// A capture that finished and was finalized: `finishCapture` leaves the plain audio `waiting`.
    private func finishedCapture(_ uploader: RecordingUploader, bytes: Data) async throws -> (PhoneRecording, URL) {
        let file = dir.appendingPathComponent("capture-\(UUID().uuidString).m4a")
        let started = Date()
        let row = try await uploader.beginCapture(fileURL: file, startedAt: started, titleHint: "Design sync", eventID: nil)
        try bytes.write(to: file)
        let finished = try await uploader.finishCapture(
            id: row.id, endedAt: started.addingTimeInterval(60), activeDuration: 60, titleHint: "Design sync", eventID: nil)
        return (try XCTUnwrap(finished), file)
    }

    func testSealPendingEncryptsTheFileKeepsThePlainAudioAndStoresTheEnvelope() async throws {
        let (uploader, store, _) = try makeStack()
        let audio = Data((0 ..< 3_000).map { UInt8($0 % 251) })
        let (recording, file) = try await finishedCapture(uploader, bytes: audio)

        let sealedCount = try await uploader.sealPending()

        XCTAssertEqual(sealedCount, 1)
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .waiting, "sealed, not yet sent")
        XCTAssertEqual(row.sealedPath, "\(recording.id).enc")
        let sealed = sealedFile(recording.id)
        XCTAssertEqual(try Data(contentsOf: file), audio, "ask #89 A: the plain audio stays until the Mac confirms it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealed.path))
        XCTAssertNotEqual(try Data(contentsOf: sealed), audio)

        // The stored envelope opens at the hub to the upload record, whose descriptor decrypts the sealed file.
        let envelope = try XCTUnwrap(row.envelope)
        let wireName = try XCTUnwrap(row.wireName)
        XCTAssertEqual(wireName, try wire(recording.id))
        let zone = InMemoryCloudTransport()
        try await zone.save([CloudRecord(
            recordName: wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: envelope,
            assetFileURL: sealed)])
        let hubView = try await TestE2E.hubTransport(inner: zone).changes(in: .relay, since: nil)
        let opened = try XCTUnwrap(hubView.changed.first)
        XCTAssertEqual(opened.recordName, "recupload-\(recording.id)")
        let payload = try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: opened.payload)
        XCTAssertEqual(payload.id, recording.id)
        XCTAssertEqual(payload.deviceID, Self.deviceID)
        let decrypted = dir.appendingPathComponent("decrypted.m4a")
        try ChunkedAssetCipher.decryptFile(at: sealed, to: decrypted, descriptor: try XCTUnwrap(opened.asset))
        XCTAssertEqual(try Data(contentsOf: decrypted), audio)
    }

    func testSealPendingWhileLockedKeepsThePlainFileAndSealsAfterUnlock() async throws {
        let spy = SpyTransport()
        let (uploader, store, _) = try makeStack(transport: spy)
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 7, count: 128))

        phoneKeys.isLocked = true
        let lockedSeal = try await uploader.sealPending()
        let lockedSend = try await uploader.uploadPending()

        XCTAssertEqual(lockedSeal, 0)
        XCTAssertEqual(lockedSend, 0)
        let waiting = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertNil(waiting.envelope)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the only copy stays until it is sealed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
        let savedWhileLocked = await spy.saves
        XCTAssertTrue(savedWhileLocked.isEmpty)

        phoneKeys.isLocked = false
        let sent = try await uploader.uploadPending()

        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "kept until the Mac confirms it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
    }

    /// Review Focus 2: the relaunch retry sends the stored envelope and the same sealed file, never a re-seal
    /// (a re-seal would carry a new nonce and seq, and the hub would see a different record version).
    func testRelaunchRetryResendsTheStoredEnvelopeByteForByte() async throws {
        let spy = SpyTransport()
        let store = try makeStore()
        let clock = TestClock()
        let first = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) { clock.now }
        let (recording, _) = try await finishedCapture(first, bytes: Data(repeating: 3, count: 2_048))
        let firstPass = try await first.uploadPending()
        XCTAssertEqual(firstPass, 1)

        // The relaunch re-save waits for its backoff (board #724).
        clock.advance(RecordingUploader.retryDelays[0])
        let relaunched = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) {
            clock.now
        }
        let resent = try await relaunched.uploadPending()

        XCTAssertEqual(resent, 1)
        let saves = await spy.saves
        guard saves.count == 2 else { return XCTFail("expected two saves, got \(saves.count)") }
        XCTAssertEqual(saves.map(\.name), [try wire(recording.id), try wire(recording.id)])
        XCTAssertEqual(saves[0].payload, saves[1].payload, "the identical envelope bytes")
        XCTAssertNotNil(saves[0].asset)
        XCTAssertEqual(saves[0].asset, saves[1].asset, "the identical sealed asset")
    }

    func testRetryAfterAFailedEchoReusesTheEnvelope() async throws {
        let spy = SpyTransport()
        let (uploader, store, _) = try makeStack(transport: spy)
        let (recording, _) = try await finishedCapture(uploader, bytes: Data(repeating: 9, count: 512))
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "disk full"))

        try await uploader.retryFailed(id: recording.id)

        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .uploading)
        let saves = await spy.saves
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0], saves[1], "Retry re-sends the stored envelope and sealed file")
    }

    /// Final review Kit I1: byte identity matters only within an epoch. A stored envelope sealed under an epoch
    /// the phone has since moved past (two rotations while it was offline, or the hub's D10 grace over) would be
    /// refused by the hub for good, so Retry re-seals it under the current epoch: the same wire name (the hub's
    /// ledger still dedupes), a new envelope and a freshly sealed asset; the plain audio stays.
    func testRetryReSealsAnEnvelopeOfAnOlderEpochUnderTheCurrentOne() async throws {
        let spy = SpyTransport()
        let (uploader, store, _) = try makeStack(transport: spy)
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 9, count: 512))
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "Upload stuck"))
        let stale = try XCTUnwrap(try store.phoneRecording(id: recording.id)?.envelope)
        XCTAssertEqual(try Envelope.parse(stale).header.epoch, 1)

        // The Mac rotated twice while the phone was away: its keybox now carries epochs 2 and 3.
        let rotated = try XCTUnwrap(try TestE2E.phoneStore(epochs: [2, 3]).hubLink(TestE2E.hubID.uuidString))
        try phoneKeys.saveHubLink(rotated)
        try await uploader.retryFailed(id: recording.id)

        let saves = await spy.saves
        guard saves.count == 2 else { return XCTFail("expected two saves, got \(saves.count)") }
        XCTAssertEqual(saves[1].name, saves[0].name, "the same wire name: the hub's ledger dedupes")
        XCTAssertEqual(try Envelope.parse(saves[1].payload).header.epoch, 3, "re-sealed under the current epoch")
        XCTAssertNotEqual(saves[1].asset, saves[0].asset, "the audio is sealed again under a fresh asset key")
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .uploading)
        XCTAssertEqual(row.envelope, saves[1].payload, "the new envelope is the stored one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the plain audio waits for the Mac")
    }

    /// A re-seal never rewrites the file an older queued save still points at: each seal gets its own name
    /// (`<id>.enc`, then `<id>-1.enc`, …). While the row waits for its new seal the sweep keeps the old file; once
    /// the new seal's save has replaced the queued one the superseded file goes.
    func testAReSealWritesANewFileAndRemovesTheSupersededOneOnceStored() async throws {
        let spy = SpyTransport()
        let store = try makeStore()
        let clock = TestClock()
        let uploader = RecordingUploader(
            transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) { clock.now }
        let (recording, _) = try await finishedCapture(uploader, bytes: Data(repeating: 6, count: 512))
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "Upload stuck"))
        let first = sealedFile(recording.id)
        let firstBytes = try Data(contentsOf: first)
        let stale = try XCTUnwrap(try store.phoneRecording(id: recording.id)?.envelope)

        // The seal is forgotten (a rotation): until the re-seal stores its envelope the old file stays known.
        XCTAssertTrue(try store.clearPhoneRecordingSeal(id: recording.id, envelope: stale))
        let swept = try await uploader.sweepOrphanFiles()
        XCTAssertTrue(swept.isEmpty, "\(swept.map(\.lastPathComponent))")
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)

        try phoneKeys.saveHubLink(try XCTUnwrap(try TestE2E.phoneStore(epochs: [1, 2]).hubLink(TestE2E.hubID.uuidString)))
        // Review: the new envelope is stored but its save fails: the queued save still points at the old file.
        await spy.setFailing(true)
        try await uploader.retryFailed(id: recording.id)
        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.sealedPath, "\(recording.id)-1.enc")
        XCTAssertEqual(try Data(contentsOf: first), firstBytes, "kept while no save replaced the queued one")
        await spy.setFailing(false)
        let waiting = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        let due = try XCTUnwrap(RecordingUploader.nextAttemptAt(attempts: waiting.uploadAttempts, last: waiting.lastAttemptAt))
        clock.advance(due.timeIntervalSince(clock.now) + 1)
        _ = try await uploader.uploadPending()

        let saves = await spy.saves.filter { $0.file != nil }
        guard saves.count == 3 else { return XCTFail("expected three saves, got \(saves.count)") }
        XCTAssertEqual(saves[1], saves[2], "the retry re-sends the stored re-seal")
        XCTAssertEqual(saves[1].file, "\(recording.id)-1.enc", "a new file per seal")
        XCTAssertEqual(saves[0].file, "\(recording.id).enc")
        XCTAssertEqual(saves[1].name, saves[0].name)
        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.sealedPath, "\(recording.id)-1.enc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the superseded file goes once the new save replaced the queued one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(recording.id)-1.enc").path))
        let afterReseal = try await uploader.sweepOrphanFiles()
        XCTAssertTrue(afterReseal.isEmpty, "\(afterReseal.map(\.lastPathComponent))")

        // A second re-seal counts on.
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "Upload stuck"))
        try phoneKeys.saveHubLink(try XCTUnwrap(try TestE2E.phoneStore(epochs: [2, 3]).hubLink(TestE2E.hubID.uuidString)))
        try await uploader.retryFailed(id: recording.id)
        let third = await spy.saves
        XCTAssertEqual(third.last?.file, "\(recording.id)-2.enc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(recording.id)-1.enc").path))
    }

    /// Re-review: a seal pass that runs while a save of the same row is in flight (the actor is suspended in the
    /// save) neither re-seals that row nor lets the send delete the seal the row stores when it resumes.
    func testASealPassDuringAnInFlightSaveNeverLosesTheStoredSeal() async throws {
        let spy = SpyTransport()
        let (uploader, store, _) = try makeStack(transport: spy)
        let (recording, _) = try await finishedCapture(uploader, bytes: Data(repeating: 4, count: 512))
        _ = try await uploader.uploadPending()
        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "Upload stuck"))
        try phoneKeys.saveHubLink(try XCTUnwrap(try TestE2E.phoneStore(epochs: [1, 2]).hubLink(TestE2E.hubID.uuidString)))

        await spy.holdSaves()
        let retry = Task { try await uploader.retryFailed(id: recording.id) }
        for _ in 0 ..< 500 {
            if await spy.heldCount > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let held = await spy.heldCount
        XCTAssertEqual(held, 1, "the re-seal's save is in flight")
        // The Mac rotated again meanwhile: the in-flight envelope (epoch 2) is now stale.
        try phoneKeys.saveHubLink(try XCTUnwrap(try TestE2E.phoneStore(epochs: [2, 3]).hubLink(TestE2E.hubID.uuidString)))
        _ = try await uploader.sealPending()
        await spy.release()
        try await retry.value

        let row = try XCTUnwrap(try store.phoneRecording(id: recording.id))
        let sealed = try XCTUnwrap(row.sealedFileURL(in: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealed.path), "the stored seal \(sealed.lastPathComponent) survives")
        XCTAssertNil(row.failure)
    }

    /// A pass (not only Retry) re-seals a stale-epoch row before it re-sends it: the relaunch retry of an
    /// in-flight upload after a rotation.
    func testARelaunchPassReSealsAnInFlightEnvelopeOfAnOlderEpoch() async throws {
        let spy = SpyTransport()
        let store = try makeStore()
        let clock = TestClock()
        let first = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) { clock.now }
        let (recording, _) = try await finishedCapture(first, bytes: Data(repeating: 3, count: 2_048))
        _ = try await first.uploadPending()

        try phoneKeys.saveHubLink(try XCTUnwrap(try TestE2E.phoneStore(epochs: [1, 2]).hubLink(TestE2E.hubID.uuidString)))
        clock.advance(RecordingUploader.retryDelays[0])
        let relaunched = RecordingUploader(transport: try phone(spy), store: store, directory: dir, deviceID: Self.deviceID) {
            clock.now
        }
        let resent = try await relaunched.uploadPending()

        XCTAssertEqual(resent, 1)
        let saves = await spy.saves
        guard saves.count == 2 else { return XCTFail("expected two saves, got \(saves.count)") }
        XCTAssertEqual(saves[1].name, try wire(recording.id))
        XCTAssertEqual(try Envelope.parse(saves[1].payload).header.epoch, 2)
    }

    /// The cap is the spec's 90 MB of audio: the plain size decides, before sealing adds its tags.
    func testTheNinetyMBCapIsCheckedOnThePlainSizeBeforeSealing() async throws {
        let store = try makeStore()
        let atCap = RecordingUploader(transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID, maxAssetBytes: 64)
        let fits = try await register(atCap, file: try makeAudioFile(name: "fits.m4a", bytes: 64))
        let sent = try await atCap.uploadPending()
        XCTAssertEqual(sent, 1, "64 plain bytes fit a 64-byte cap although the sealed file is larger")
        XCTAssertEqual(try store.phoneRecording(id: fits.id)?.state, .uploading)

        let underCap = RecordingUploader(transport: try phone(), store: store, directory: dir, deviceID: Self.deviceID, maxAssetBytes: 63)
        let over = try await register(underCap, file: try makeAudioFile(name: "over.m4a", bytes: 64))
        let sealedCount = try await underCap.sealPending()
        XCTAssertEqual(sealedCount, 0)
        let row = try XCTUnwrap(try store.phoneRecording(id: over.id))
        XCTAssertEqual(row.failure, .tooLarge)
        XCTAssertNil(row.envelope)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("over.m4a").path), "the only copy is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedFile(over.id).path), "nothing is sealed past the cap")
    }

    func testReceivedDeletesTheSealedFile() async throws {
        let (uploader, store, _) = try makeStack()
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 1, count: 256))
        _ = try await uploader.uploadPending()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))

        try await uploader.applyEcho(echo(for: recording, status: .received))

        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Ask #89 A: a sealed row that the Mac has not confirmed owns its plain audio AND its sealed copy, so the
    /// launch sweep keeps both; once delivered it owns neither.
    func testTheSweepKeepsBothFilesOfAnUndeliveredSealedRow() async throws {
        let (uploader, store, _) = try makeStack()
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 2, count: 256))
        _ = try await uploader.sealPending()

        let removed = try await uploader.sweepOrphanFiles()

        XCTAssertTrue(removed.isEmpty, "\(removed.map(\.lastPathComponent))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))

        try store.setPhoneRecordingState(id: recording.id, state: .delivered)
        let afterDelivery = try await uploader.sweepOrphanFiles()

        XCTAssertEqual(Set(afterDelivery.map(\.lastPathComponent)), [file.lastPathComponent, "\(recording.id).enc"])
    }

    /// Ask #89 A: a recording registered again under an id that left a sealed copy behind (a held recording
    /// adopted after a re-link) is sealed fresh: the stale `<id>.enc`, sealed to the old pairing, is dropped.
    func testRegisteringAgainDropsAStaleSealedCopyAndSealsFresh() async throws {
        let (uploader, store, _) = try makeStack()
        let id = UUID().uuidString
        let stale = sealedFile(id)
        try Data("sealed to the old pairing".utf8).write(to: stale)
        let staleReseal = dir.appendingPathComponent("\(id)-2.enc")
        try Data("re-sealed to the old pairing".utf8).write(to: staleReseal)
        let file = try makeAudioFile(name: "\(id).m4a", bytes: 512)

        let ended = Date()
        let row = try await uploader.register(
            id: id, fileURL: file, startedAt: ended.addingTimeInterval(-30), endedAt: ended, titleHint: nil)

        XCTAssertNotNil(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "the old pairing's copy is dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleReseal.path), "every seal generation of it")
        let sealedCount = try await uploader.sealPending()
        XCTAssertEqual(sealedCount, 1)
        XCTAssertNotNil(try store.phoneRecording(id: id)?.envelope)
        XCTAssertNotEqual(try Data(contentsOf: stale), Data("sealed to the old pairing".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Ask #89 A: a `failed` echo keeps both copies (Retry re-sends the stored envelope: see the Retry tests).
    func testAFailedEchoKeepsThePlainAndTheSealedFile() async throws {
        let (uploader, store, _) = try makeStack()
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 8, count: 256))
        _ = try await uploader.uploadPending()

        try await uploader.applyEcho(echo(for: recording, status: .failed, errorMessage: "disk full"))

        XCTAssertEqual(try store.phoneRecording(id: recording.id)?.state, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
    }

    /// `sealPending` is public and a pass seals too: overlapping calls seal each recording once, and no call
    /// overwrites or deletes another's sealed file.
    func testOverlappingSealCallsSealEachRecordingOnce() async throws {
        let (uploader, store, _) = try makeStack()
        var ids: [String] = []
        for byte in UInt8(1) ... 3 {
            ids.append(try await finishedCapture(uploader, bytes: Data(repeating: byte, count: 4_096)).0.id)
        }

        async let first = uploader.sealPending()
        async let second = uploader.sealPending()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a + b, 3)
        for id in ids {
            XCTAssertNotNil(try store.phoneRecording(id: id)?.envelope, id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(id).path), id)
        }
    }

    /// Review fix 1: the launch sweep can run while a seal is suspended in `transport.seal`, after `<id>.enc` is
    /// written and before `sealed_path` is stored. It must keep both files, and the row ends sealed.
    func testTheSweepDuringASealKeepsBothFilesAndTheRowEndsSealed() async throws {
        let keys = GatedKeyProvider(try TestE2E.phone(store: phoneKeys))
        let store = try makeStore()
        let uploader = RecordingUploader(
            transport: TestE2E.phoneTransport(keys), store: store, directory: dir, deviceID: Self.deviceID)
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 5, count: 2_048))
        let entered = expectation(description: "the seal is inside transport.seal")
        keys.hold { entered.fulfill() }

        let sealing = Task { try await uploader.sealPending() }
        await fulfillment(of: [entered], timeout: 5)
        let removed = try await uploader.sweepOrphanFiles()
        XCTAssertTrue(removed.isEmpty, "\(removed.map(\.lastPathComponent))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
        keys.release()
        let sealedCount = try await sealing.value

        XCTAssertEqual(sealedCount, 1)
        XCTAssertNotNil(try store.phoneRecording(id: recording.id)?.envelope)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "ask #89 A: the plain audio waits for the Mac")
    }

    /// Review fix 2: a seal error that is not "locked" belongs to its row: rows already sealed are still sent,
    /// and the failing row stays waiting with its plain file for the next pass.
    func testASealErrorOnOneRowStillSendsTheRowsAlreadySealed() async throws {
        let keys = GatedKeyProvider(try TestE2E.phone(store: phoneKeys))
        let spy = SpyTransport()
        let store = try makeStore()
        let uploader = RecordingUploader(
            transport: TestE2E.phoneTransport(keys, inner: spy), store: store, directory: dir, deviceID: Self.deviceID)
        let (ready, _) = try await finishedCapture(uploader, bytes: Data(repeating: 1, count: 256))
        _ = try await uploader.sealPending()
        let (failing, file) = try await finishedCapture(uploader, bytes: Data(repeating: 2, count: 256))
        keys.failNextSeq = true

        let sent = try await uploader.uploadPending()

        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try store.phoneRecording(id: ready.id)?.state, .uploading)
        let row = try XCTUnwrap(try store.phoneRecording(id: failing.id))
        XCTAssertEqual(row.state, .waiting)
        XCTAssertNil(row.envelope)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedFile(failing.id).path))
        let retried = try await uploader.uploadPending()
        XCTAssertEqual(retried, 1, "the next pass seals and sends it")
    }

    /// Review fix 3: a pre-E2E `uploading` row the locked launch pass could not seal is sent by the pass that
    /// seals it, not left until the next relaunch.
    func testAPreE2EUploadingRowSealedAfterTheLaunchPassIsSentInThatPass() async throws {
        let spy = SpyTransport()
        let (uploader, store, _) = try makeStack(transport: spy)
        let legacy = try await register(uploader, file: try makeAudioFile(name: "legacy.m4a"))
        try store.setPhoneRecordingState(id: legacy.id, state: .uploading)
        phoneKeys.isLocked = true
        let launch = try await uploader.uploadPending()
        XCTAssertEqual(launch, 0)

        phoneKeys.isLocked = false
        let later = try await uploader.uploadPending()

        XCTAssertEqual(later, 1)
        let saves = await spy.savedNames
        XCTAssertEqual(saves, [try wire(legacy.id)])
    }

    /// Review fix 4: the row update failing after the seal never leaves a sealed file without its envelope;
    /// the plain file stays for the retry.
    func testAStoreWriteFailureWhileSealingRemovesTheSealedFileAndKeepsThePlain() async throws {
        let (uploader, store, _) = try makeStack()
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 6, count: 256))
        try await store.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_seal BEFORE UPDATE OF envelope ON phone_recordings
                BEGIN SELECT RAISE(ABORT, 'store write failed'); END
                """)
        }

        let sealedCount = try await uploader.sealPending()

        XCTAssertEqual(sealedCount, 0)
        XCTAssertNil(try store.phoneRecording(id: recording.id)?.envelope)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
    }

    func testDiscardRemovesTheSealedFile() async throws {
        let (uploader, store, _) = try makeStack()
        let (recording, file) = try await finishedCapture(uploader, bytes: Data(repeating: 4, count: 256))
        _ = try await uploader.sealPending()

        try await uploader.discard(id: recording.id)

        XCTAssertNil(try store.phoneRecording(id: recording.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedFile(recording.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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
    struct Save: Equatable {
        let name: String
        let payload: Data
        /// The asset file's bytes when it was saved.
        let asset: Data?
        /// The asset file's name.
        let file: String?
    }

    private(set) var savedNames: [String] = []
    private(set) var saves: [Save] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    func holdSaves() { holding = true }

    /// While true every save is recorded, then throws (a transient failure).
    private(set) var failing = false
    func setFailing(_ failing: Bool) { self.failing = failing }

    func release() {
        holding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func save(_ records: [CloudRecord]) async throws {
        savedNames += records.map(\.recordName)
        saves += records.map { record in
            Save(
                name: record.recordName, payload: record.payload,
                asset: record.assetFileURL.flatMap { try? Data(contentsOf: $0) }, file: record.assetFileURL?.lastPathComponent)
        }
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        if failing { throw SaveFailed() }
    }

    struct SaveFailed: Error {}

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: CloudChangeToken(value: 0))
    }
}

/// The paired phone's keys with a gate in `nextSeq` (called only inside `SecureTransport.seal`): `hold` makes
/// the next call signal `entered` and block until `release`, so a test can act while a seal is suspended;
/// `failNextSeq` makes the next call throw a non-lock error.
private final class GatedKeyProvider: SecureKeyProvider, @unchecked Sendable {
    struct SeqFailure: Error {}

    private let inner: PhoneKeyProvider
    private let lock = NSLock()
    private var onEnter: (() -> Void)?
    private let gate = DispatchSemaphore(value: 0)
    private var failing = false

    init(_ inner: PhoneKeyProvider) { self.inner = inner }

    var role: SecureRole { inner.role }
    var failNextSeq: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func hold(onEnter: @escaping () -> Void) { lock.withLock { self.onEnter = onEnter } }
    func release() { gate.signal() }

    func nextSeq() throws -> UInt64 {
        let (enter, fail) = lock.withLock { () -> ((() -> Void)?, Bool) in
            defer { onEnter = nil; failing = false }
            return (onEnter, failing)
        }
        if fail { throw SeqFailure() }
        if let enter {
            enter()
            // Bounded: a test that never releases fails instead of hanging the run.
            _ = gate.wait(timeout: .now() + 10)
        }
        return try inner.nextSeq()
    }

    func metaKey() throws -> SymmetricKey { try inner.metaKey() }
    func currentEpoch() throws -> UInt32 { try inner.currentEpoch() }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { try inner.dataKey(epoch: epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { try inner.alertKey(epoch: epoch) }
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        try inner.relayKey(direction, deviceID: deviceID, epoch: epoch)
    }
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool {
        try inner.acceptsRelayEpoch(epoch, deviceID: deviceID)
    }
    func relayDeviceIDs() throws -> [UUID] { try inner.relayDeviceIDs() }
    func hubSigner() throws -> Curve25519.Signing.PrivateKey { try inner.hubSigner() }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { try inner.hubAgreement() }
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        try inner.keyboxRecipient(deviceID: deviceID)
    }
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { try inner.deviceSigner() }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { try inner.hubAgreementPublicKey() }
    func linkNonce() throws -> Data { try inner.linkNonce() }
}

/// The Mac's online state a test flips by hand.
private final class OnlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    var value: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }
}
