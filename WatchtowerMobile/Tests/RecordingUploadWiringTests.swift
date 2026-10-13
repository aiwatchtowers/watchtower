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

    private func makeWired() async throws -> Wired {
        let transport = InMemoryCloudTransport()
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let directory = try makeRecordingsDirectory()
        let env = try AppEnvironment(
            transport: transport,
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: directory
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

    /// The Mac's echo: the same record rewritten without the asset.
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
        try await transport.save([try CloudRecordFactory.record(for: payload, modifiedAt: Date(), assetFileURL: nil)])
    }

    // MARK: - Mac asleep

    func testAnUploadWhileTheMacSleepsStaysPendingAndSaysSo() async throws {
        let wired = try await makeWired()
        let recording = try await recordAndStop(wired)
        await wired.env.refresh(.pull)

        let uploads = try await relayUploads(in: wired.transport)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path))

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

        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL(in: wired.directory).path), "failed → the only copy is kept")
        let row = try XCTUnwrap(try wired.env.store.phoneRecording(id: recording.id))
        let stage = PhoneUploadStage(recording: row, heartbeat: nil, now: Date())
        XCTAssertEqual(stage, .failed("The Mac could not save the recording.", retryable: true))
        XCTAssertTrue(stage.offersRetry)

        await wired.env.recorder.retry(id: recording.id)
        XCTAssertEqual(try wired.env.store.phoneRecording(id: recording.id)?.state, .uploading)
        let uploads = try await relayUploads(in: wired.transport)
        XCTAssertEqual(uploads.map(\.status), [.pending], "Retry sends the same record again")
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
            deviceID: "device-a", name: "Phone A", model: "iPhone", appVersion: "1.0",
            scope: .private, userRecordName: "_user-a"
        )
        // The previous process sent one recording and finalized another
        // without sending it.
        let earlier = RecordingUploader(
            transport: InMemoryCloudTransport(), store: try ReplicaStore(path: replicaPath),
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
        try await transport.save(try DemoSeed.records(now: clock.now).filter { $0.recordName == HeartbeatPayload.recordName })
        let engine = FakeAudioEngine()
        let env = try AppEnvironment(
            transport: transport,
            replicaPath: replicaPath,
            transportKind: .cloudKit,
            linkedDevice: device,
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
        let before = try await relayUploads(in: wired.transport)
        XCTAssertTrue(before.isEmpty)

        let device = LinkedDevice(
            deviceID: "device-b", name: "Phone B", model: "iPhone", appVersion: "1.0",
            scope: .private, userRecordName: "_user-b"
        )
        await wired.env.setLinkedDevice(device)

        XCTAssertEqual(wired.env.linkedDevice, device)
        XCTAssertEqual(wired.env.deviceSettings.linkedDevice, device)
        let uploads = try await relayUploads(in: wired.transport)
        XCTAssertEqual(uploads.map(\.deviceID), ["device-b"])
        let actionID = try await wired.env.outbox.enqueue(kind: .probe, entityRecordName: nil)
        XCTAssertFalse(actionID.isEmpty, "the outbox is linked too")
    }
}
