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
            defaults: try makeDefaults()
        ) { uploader in
            PhoneRecorderController(
                uploader: uploader,
                engine: engine,
                directory: directory,
                notificationCenter: NotificationCenter(),
                now: { clock.now },
                tickInterval: nil
            )
        }
        addTeardownBlock { @MainActor in env.stop() }
        try await poll { env.isLooping }
        return Wired(env: env, transport: transport, engine: engine, clock: clock)
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
        await wired.env.refresh()

        let uploads = try await relayUploads(in: wired.transport)
        XCTAssertEqual(uploads.map(\.status), [.pending], "no echo from a sleeping Mac")
        XCTAssertEqual(uploads.first?.deviceID, DemoSeed.device.deviceID)
        XCTAssertEqual(try wired.env.store.phoneRecording(id: recording.id)?.state, .uploading)

        let model = wired.env.phoneRecordings
        try await poll { model.snapshot.recording(recording.id) != nil && model.snapshot.heartbeat != nil }
        let row = try XCTUnwrap(model.snapshot.recording(recording.id))
        let heartbeat = model.snapshot.heartbeat
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: heartbeat, now: Date()).label, "Sending to your Mac")
        let asleep = PhoneUploadStage(recording: row, heartbeat: heartbeat, now: Date().addingTimeInterval(800))
        XCTAssertEqual(asleep, .waitingForMac)
        XCTAssertEqual(asleep.label, "Waiting for the Mac to wake")
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: nil, now: Date()), .waitingForMac)
    }

    // MARK: - Ack

    func testReceivedEchoDeletesTheLocalFile() async throws {
        let wired = try await makeWired()
        let recording = try await recordAndStop(wired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL.path))

        try await echo(recording, status: .received, in: wired.transport)
        await wired.env.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.fileURL.path), "received → the local copy goes")
        let row = try XCTUnwrap(try wired.env.store.phoneRecording(id: recording.id))
        XCTAssertEqual(row.state, .delivered)
        XCTAssertEqual(PhoneUploadStage(recording: row, heartbeat: nil, now: Date()).label, "Sent to your Mac")
    }

    func testFailedEchoKeepsTheFileAndOffersRetry() async throws {
        let wired = try await makeWired()
        let recording = try await recordAndStop(wired)

        try await echo(recording, status: .failed, error: "The Mac could not save the recording.", in: wired.transport)
        await wired.env.refresh()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.fileURL.path), "failed → the only copy is kept")
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
