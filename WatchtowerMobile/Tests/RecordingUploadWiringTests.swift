import UIKit
import WatchtowerE2ETesting
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The recorder wired into the app (spec §5.3, §9): the environment's
/// uploader sends the recording to RelayZone, the relay feed routes the
/// Mac's echo back, and the upload line follows the heartbeat. Fake audio
/// engine and fake clock; the demo transport stands in for iCloud.
@MainActor
final class RecordingUploadWiringTests: XCTestCase {
    private struct Wired {
        let env: AppEnvironment
        let transport: InMemoryCloudTransport
        let engine: FakeAudioEngine
        let clock: FakeClock
        let directory: URL
    }

    /// `gate` wraps the transport (held relay saves); `keys` replaces the demo pairing's (same material, a
    /// handle the test locks); `notifications` carries the unlock signal.
    private func makeWired(
        gate: RelayHoldTransport? = nil,
        keys: PhoneKeys? = nil,
        notifications: NotificationCenter = NotificationCenter()
    ) async throws -> Wired {
        let transport = gate?.inner ?? InMemoryCloudTransport()
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let directory = try makeRecordingsDirectory()
        let env = try AppEnvironment(
            transport: gate ?? transport,
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            keys: keys,
            defaults: try makeDefaults(),
            recordingsDirectory: directory,
            notifications: notifications
        ) { uploader in
            PhoneRecorderController(
                uploader: uploader,
                engine: engine,
                notificationCenter: NotificationCenter(),
                now: { clock.now },
                tickInterval: nil
            )
        }
        addTeardownBlock { @MainActor in env.stop() }
        try await poll { env.isLooping }
        return Wired(env: env, transport: transport, engine: engine, clock: clock, directory: directory)
    }

    /// Records 30 s and stops; returns the saved ledger row.
    private func recordAndStop(_ wired: Wired) async throws -> PhoneRecording {
        await wired.env.recorder.recordVoiceNote()
        wired.clock.advance(30)
        await wired.env.recorder.stop()
        let saved = try XCTUnwrap(wired.env.recorder.savedRecording, "expected a saved recording")
        return try XCTUnwrap(try wired.env.store.phoneRecording(id: saved.id))
    }

    /// The Mac's echo: the same record rewritten without the asset, sealed
    /// by the demo hub to the demo phone.
    private func echo(
        _ recording: PhoneRecording,
        status: RecordingUploadStatus,
        error: String? = nil,
        in transport: InMemoryCloudTransport
    ) async throws {
        let payload = RecordingUploadPayload(
            id: recording.id, startedAt: recording.startedAt, endedAt: recording.endedAt,
            durationSec: recording.durationSec, sampleFormat: recording.sampleFormat,
            status: status, errorMessage: error, deviceID: DemoSeed.device.deviceID
        )
        try await TestPhone.hub(over: transport, .demo).save([
            try CloudRecordFactory.record(for: payload, modifiedAt: Date(), assetFileURL: nil)
        ])
    }

    // MARK: - Mac asleep

    func testAnUploadWhileTheMacSleepsStaysPendingAndSaysSo() async throws {
        let wired = try await makeWired()
        let recording = try await recordAndStop(wired)
        await wired.env.refresh(.pull)

        let uploads = try await relayUploads(in: wired.transport, .demo)
        XCTAssertEqual(uploads.map(\.status), [.pending], "no echo from a sleeping Mac")
        XCTAssertEqual(uploads.first?.deviceID, DemoSeed.device.deviceID)
        XCTAssertEqual(try wired.env.store.phoneRecording(id: recording.id)?.state, .uploading)

        let model = wired.env.phoneRecordings
        try await poll { model.snapshot.recording(recording.id) != nil && model.snapshot.heartbeat != nil }
        let row = try XCTUnwrap(model.snapshot.recording(recording.id))
        let heartbeat = model.snapshot.heartbeat
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: heartbeat, now: Date()).label, "Sending to your Mac")
        let asleep = PhoneUploadStage(recording: row, heartbeat: heartbeat, now: Date().addingTimeInterval(3_600))
        XCTAssertEqual(asleep, .waitingForMac)
        XCTAssertEqual(asleep.label, "Waiting for the Mac to wake")
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: nil, now: Date()), .waitingForMac)
    }

    /// An app relaunched while the Mac sleeps leaves an upload in flight
    /// alone (it waits in CloudKit's queue): no re-save and no attempt
    /// counted, so it reads "Waiting for the Mac to wake", never "Upload
    /// stuck". A relaunch that finds the Mac online re-saves it when due.
    func testARelaunchWhileTheMacSleepsNeitherResavesNorCountsAnAttempt() async throws {
        let transport = InMemoryCloudTransport()
        let path = try makeReplicaPath()
        let defaults = try makeDefaults()
        let directory = try makeRecordingsDirectory()
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let launch: (Date) throws -> AppEnvironment = { now in
            let env = try AppEnvironment(
                transport: transport,
                replicaPath: path,
                transportKind: .inMemoryDemo,
                defaults: defaults,
                recordingsDirectory: directory,
                uploadRetriesAllowed: true,
                makeRecorder: { uploader in
                    PhoneRecorderController(
                        uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                        now: { clock.now }, tickInterval: nil
                    )
                },
                now: { now }
            )
            self.addTeardownBlock { @MainActor in env.stop() }
            return env
        }
        let first = try launch(Date())
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(30)
        await first.recorder.stop()
        let id = try XCTUnwrap(first.recorder.savedRecording?.id)
        XCTAssertEqual(try first.store.phoneRecording(id: id)?.uploadAttempts, 1)
        first.stop()

        // Two hours on: the backoff is due, but the heartbeat the boot
        // brings is two hours old.
        let asleepAt = Date().addingTimeInterval(7_200)
        let asleep = try launch(asleepAt)
        try await poll { asleep.isBootstrapped }
        let row = try XCTUnwrap(try asleep.store.phoneRecording(id: id))
        XCTAssertEqual(row.state, .uploading)
        XCTAssertEqual(row.uploadAttempts, 1, "no re-save while the Mac sleeps")
        let model = asleep.phoneRecordings
        try await poll { model.snapshot.heartbeat != nil }
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: model.snapshot.heartbeat, now: asleepAt), .waitingForMac)
        asleep.stop()

        let awake = try launch(Date().addingTimeInterval(RecordingUploader.retryDelays[0] + 1))
        try await poll { awake.isBootstrapped }
        XCTAssertEqual(try awake.store.phoneRecording(id: id)?.uploadAttempts, 2, "the Mac is online: re-saved")
    }

    // MARK: - Ack

    func testReceivedEchoDeletesTheLocalFile() async throws {
        let wired = try await makeWired()
        let recording = try await recordAndStop(wired)
        XCTExpectFailure("E2E ask #89: plain .m4a deleted after sealing breaks the #63 hold/hand-over", strict: true) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path))
        }

        try await echo(recording, status: .received, in: wired.transport)
        await wired.env.refresh(.pull)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path), "received → the local copy goes")
        let row = try XCTUnwrap(try wired.env.store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .delivered)
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: nil, now: Date()).label, "Sent to your Mac")
    }

    func testFailedEchoKeepsTheFileAndOffersRetry() async throws {
        let wired = try await makeWired()
        let recording = try await recordAndStop(wired)

        try await echo(recording, status: .failed, error: "The Mac could not save the recording.", in: wired.transport)
        await wired.env.refresh(.pull)

        XCTExpectFailure("E2E ask #89: plain .m4a deleted after sealing breaks the #63 hold/hand-over", strict: true) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path), "failed → the only copy is kept")
        }
        let row = try XCTUnwrap(try wired.env.store.phoneRecording(id: recording.id))
        let stage = PhoneUploadStage(recording: row, heartbeat: nil, now: Date())
        XCTAssertEqual(stage, .failed("The Mac could not save the recording.", retryable: true))
        XCTAssertTrue(stage.offersRetry)

        await wired.env.recorder.retry(id: recording.id)
        XCTAssertEqual(try wired.env.store.phoneRecording(id: recording.id)?.state, .uploading)
        let uploads = try await relayUploads(in: wired.transport, .demo)
        XCTAssertEqual(uploads.map(\.status), [.pending], "Retry sends the same record again")
    }

    // MARK: - Sealing and file protection (mobile E2E Task 17)

    /// A finished recording is sealed at once, even while an earlier upload pass hangs on a slow save: no
    /// plaintext audio waits for the network.
    func testFinishSealsTheRecordingAndRemovesThePlainFile() async throws {
        let gate = RelayHoldTransport()
        // The demo pairing passed in: the environment picks it on its own only over the in-memory transport.
        let wired = try await makeWired(gate: gate, keys: try DemoSeed.phoneKeys())
        // A recording made while unlinked waits unsealed; relinking starts a pass whose save hangs.
        await wired.env.setLinkedDevice(nil)
        _ = try await recordAndStop(wired)
        await gate.hold()
        let relink = Task { await wired.env.setLinkedDevice(DemoSeed.device) }
        try await poll({ gate.heldCount == 1 }, "the upload pass hangs on its save")

        await wired.env.recorder.recordVoiceNote()
        wired.clock.advance(30)
        let stopping = Task { await wired.env.recorder.stop() }
        try await poll { wired.env.recorder.savedRecording != nil }
        let id = try XCTUnwrap(wired.env.recorder.savedRecording?.id)

        try await poll(
            { (try? wired.env.store.phoneRecording(id: id))?.sealedPath != nil },
            "the finished recording waited for the hanging upload pass to be sealed"
        )
        let row = try XCTUnwrap(try wired.env.store.phoneRecording(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: row.fileURL(in: wired.directory).path), "the plain audio is gone")
        let sealed = try XCTUnwrap(row.sealedFileURL(in: wired.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealed.path), "the sealed copy waits for the Mac")
        XCTAssertNotEqual(try Data(contentsOf: sealed), Data(repeating: 0x5A, count: 256), "the copy is ciphertext")
        await gate.release()
        await relink.value
        await stopping.value
        XCTAssertEqual(try wired.env.store.phoneRecording(id: id)?.state, .uploading)
    }

    /// A recording finished while the keychain is locked keeps its plain file (`.completeUnlessOpen`) and is
    /// sealed and sent at the unlock signal.
    func testUnlockSealsARecordingFinishedWhileLocked() async throws {
        let keys = try DemoSeed.phoneKeys()
        let keychain = try XCTUnwrap(keys.store as? InMemoryPhoneKeyStore)
        let notifications = NotificationCenter()
        let wired = try await makeWired(keys: keys, notifications: notifications)
        keychain.isLocked = true
        let recording = try await recordAndStop(wired)
        XCTAssertNil(recording.sealedPath, "nothing is sealed while locked")
        XCTAssertEqual(recording.state, .waiting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path))

        keychain.isLocked = false
        notifications.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

        try await poll(
            { (try? wired.env.store.phoneRecording(id: recording.id))?.state == .uploading },
            "the unlock did not seal and send the recording"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path))
        let uploads = try await relayUploads(in: wired.transport, .demo)
        XCTAssertEqual(uploads.map(\.id), [recording.id])
    }

    /// D8: ciphertext (the replica's and the transport's directory, the incoming asset stash, the recordings
    /// folder) and the hold with its manifest are class C, readable in the background after the first unlock;
    /// plaintext audio (the capture) is `.completeUnlessOpen`. The simulator keeps no class, so the
    /// classes are read back from what was set (`FileProtection.observer`), and from the file system where it
    /// keeps them (a device).
    func testFileProtectionClassesAreSetOnTheDirectoriesAndTheCapture() async throws {
        let classC = FileProtectionType.completeUntilFirstUserAuthentication
        let set = ProtectionLog()
        let observer: @Sendable (URL, FileProtectionType) -> Void = { url, type in set.record(url, type) }
        try await FileProtection.$observer.withValue(observer) {
            let root = try makeRecordingsDirectory().appendingPathComponent("group", isDirectory: true)
            let live = try AppEnvironment.prepareLiveDirectory(root)
            try assertClass(of: live, classC, set, "the replica's directory")
            // The transport store lives outside the app group (board #724): its folder is class C too.
            let own = root.deletingLastPathComponent().appendingPathComponent("own", isDirectory: true)
            let store = try AppEnvironment.liveTransportStore(
                path: own.appendingPathComponent(AppEnvironment.transportStoreFileName).path)
            try assertClass(of: own, classC, set, "the transport store's directory")
            try assertClass(of: try XCTUnwrap(store.stashDirectory), classC, set, "the transport's asset stash")

            let wired = try await makeWired()
            try assertClass(of: wired.directory, classC, set, "the recordings folder")
            await wired.env.recorder.recordVoiceNote()
            let capture = try XCTUnwrap(wired.engine.begunURLs.last)
            try assertClass(of: capture, .completeUnlessOpen, set, "the capture in progress")
            wired.clock.advance(30)
            await wired.env.recorder.stop()

            let hold = try XCTUnwrap(wired.env.hold)
            let saved = try XCTUnwrap(wired.env.recorder.savedRecording)
            let row = try XCTUnwrap(try wired.env.store.phoneRecording(id: saved.id))
            try hold.hold([HeldRecording(row, marks: [], hubID: "hub-acme", macName: nil)])
            try assertClass(of: hold.directory, classC, set, "the hold folder")
            try assertClass(
                of: hold.directory.appendingPathComponent("manifest.json"), classC, set,
                "the hold's manifest (a locked wipe reads it)")
        }
    }

    /// `expected` was set on `url`, and the file system reports it where it keeps classes.
    private func assertClass(
        of url: URL,
        _ expected: FileProtectionType,
        _ set: ProtectionLog,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if let kept = try FileProtection.protection(of: url) {
            XCTAssertEqual(kept, expected, what, file: file, line: line)
        }
        XCTAssertEqual(set.last(for: url), expected, what, file: file, line: line)
    }

    // MARK: - Background

    /// The audio background mode keeps the app alive while recording; the
    /// fetch loop must still pause in the background.
    func testRecordingNeverKeepsTheFetchLoopRunningInTheBackground() async throws {
        let wired = try await makeWired()
        await wired.env.recorder.recordVoiceNote()
        wired.env.setActive(false)
        XCTAssertFalse(wired.env.isLooping)
        XCTAssertEqual(wired.env.recorder.phase, .recording, "the capture itself goes on")
        wired.env.setActive(true)
        XCTAssertTrue(wired.env.isLooping)
    }

    // MARK: - Bounded retry (board #724)

    /// A launch into the background (a silent push) uploads nothing — not
    /// the relaunch retry of a recording already sent, not a recording
    /// waiting to go — until the app becomes active; then both go out.
    func testALaunchIntoTheBackgroundUploadsNothingUntilTheAppIsActive() async throws {
        let replicaPath = try makeReplicaPath()
        let directory = try makeRecordingsDirectory()
        let clock = MutableClock()
        let device = LinkedDevice(
            deviceID: TestPhone.deviceID(), name: "Phone A", model: "iPhone", appVersion: "1.0",
            scope: .private, userRecordName: "_user-a"
        )
        // The previous process sent one recording and finalized another
        // without sending it.
        let earlier = RecordingUploader(
            transport: try TestPhone.transport(), store: try TestPhone.replica(path: replicaPath),
            directory: directory, deviceID: device.deviceID
        ) { clock.now }
        var ids: [String] = []
        for name in ["sent", "waiting"] {
            let file = directory.appendingPathComponent("\(name).m4a")
            try Data(repeating: 1, count: 64).write(to: file)
            let ended = clock.now
            let row = try await earlier.register(fileURL: file, startedAt: ended.addingTimeInterval(-60), endedAt: ended, titleHint: name)
            ids.append(try XCTUnwrap(row).id)
            if name == "sent" { _ = try await earlier.uploadPending() }
        }
        clock.advance(3_600)

        let transport = InMemoryCloudTransport()
        // The Mac is online: the relaunch retry does not wait for it.
        try await TestPhone.hub(over: transport).save(
            try DemoSeed.records(now: clock.now).filter { $0.recordName == HeartbeatPayload.recordName })
        let engine = FakeAudioEngine()
        let env = try AppEnvironment(
            transport: transport,
            replicaPath: replicaPath,
            transportKind: .cloudKit,
            hubID: TestE2E.hubID.uuidString,
            linkedDevice: device,
            keys: try TestPhone.keys(),
            defaults: try makeDefaults(),
            recordingsDirectory: directory,
            uploadRetriesAllowed: false,
            makeRecorder: { uploader in
                PhoneRecorderController(uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), tickInterval: nil)
            },
            now: { clock.now }
        )
        addTeardownBlock { @MainActor in env.stop() }
        try await poll({ env.isBootstrapped }, "the boot did not finish")
        var uploads = try await relayUploads(in: transport)
        XCTAssertTrue(uploads.isEmpty, "a background launch uploads nothing")

        env.setActive(true)
        try await poll({ (try? env.store.phoneRecordings().allSatisfy { $0.state == .uploading }) == true }, "no pass on activation")
        uploads = try await relayUploads(in: transport)
        XCTAssertEqual(Set(uploads.map(\.id)), Set(ids))
    }

    // MARK: - Link seam

    /// `setLinkedDevice` reaches Settings, the outbox and the uploader, and
    /// sends a recording that waited while the phone was unlinked.
    func testSetLinkedDeviceReachesTheUploaderAndSendsWaitingRecordings() async throws {
        let wired = try await makeWired()
        await wired.env.setLinkedDevice(nil)
        let recording = try await recordAndStop(wired)
        XCTAssertEqual(try wired.env.store.phoneRecording(id: recording.id)?.state, .waiting, "unlinked: nothing is sent")
        let before = try await relayUploads(in: wired.transport, .demo)
        XCTAssertTrue(before.isEmpty)

        let device = LinkedDevice(
            deviceID: "device-b", name: "Phone B", model: "iPhone", appVersion: "1.0",
            scope: .private, userRecordName: "_user-b"
        )
        await wired.env.setLinkedDevice(device)

        XCTAssertEqual(wired.env.linkedDevice, device)
        XCTAssertEqual(wired.env.deviceSettings.linkedDevice, device)
        let uploads = try await relayUploads(in: wired.transport, .demo)
        XCTAssertEqual(uploads.map(\.deviceID), ["device-b"])
        let actionID = try await wired.env.outbox.enqueue(kind: .probe, entityRecordName: nil)
        XCTAssertFalse(actionID.isEmpty, "the outbox is linked too")
    }
}

/// A transport whose relay saves can be held (a slow network): `hold()` parks every relay save until
/// `release()`; data-zone traffic (the demo seed) passes.
private final class RelayHoldTransport: CloudSyncTransport, @unchecked Sendable {
    let inner = InMemoryCloudTransport()
    private let lock = NSLock()
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Relay saves parked now.
    var heldCount: Int { lock.withLock { waiters.count } }

    func hold() async {
        lock.withLock { holding = true }
    }

    func release() async {
        let parked = lock.withLock {
            holding = false
            defer { waiters = [] }
            return waiters
        }
        parked.forEach { $0.resume() }
    }

    func save(_ records: [CloudRecord]) async throws {
        if records.contains(where: { $0.zone == .relay }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = lock.withLock {
                    guard holding else { return false }
                    waiters.append(continuation)
                    return true
                }
                if !parked { continuation.resume() }
            }
        }
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }
}

/// The classes `FileProtection` set, by path.
private final class ProtectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var classes: [String: FileProtectionType] = [:]

    func record(_ url: URL, _ type: FileProtectionType) {
        lock.withLock { classes[url.standardizedFileURL.path] = type }
    }

    func last(for url: URL) -> FileProtectionType? {
        lock.withLock { classes[url.standardizedFileURL.path] }
    }
}
