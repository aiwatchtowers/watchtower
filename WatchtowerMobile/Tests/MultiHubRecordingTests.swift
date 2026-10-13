import Foundation
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Recording across hubs (multi-hub spec §5.4): a recording goes to the
/// Mac that was active when it started, and that session's uploader
/// finishes it even after a switch; one microphone, so one capture at a
/// time across hubs; the Recordings list shows the active hub's
/// recordings; sessions adopting their held recordings at one boot never
/// clobber the shared hold manifest.
@MainActor
final class MultiHubRecordingTests: XCTestCase {
    private let device = LinkedDevice(
        deviceID: "device-acme-1",
        name: "Acme iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    private struct Hub {
        let session: HubSession
        let transport: InMemoryCloudTransport
        let clock: FakeClock
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("multi-hub-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    private func paths(_ base: URL) -> HubPaths {
        HubPaths(
            groupDirectory: base.appendingPathComponent("g"),
            localDirectory: base.appendingPathComponent("l"),
            recordingsBase: base.appendingPathComponent("r")
        )
    }

    /// A cloudKit-kind session on `hubID`'s files over its own in-memory
    /// transport and a fake audio engine; its safety poll waits for good.
    /// `replicaPath` overrides the hub's replica (the hold's seed sessions).
    private func makeHub(
        _ hubID: String,
        base: URL,
        linked: Bool = true,
        replicaPath: String? = nil
    ) throws -> Hub {
        let paths = paths(base)
        try paths.prepare(hubID)
        let transport = InMemoryCloudTransport()
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let session = try HubSession(
            transport: transport,
            replicaPath: replicaPath ?? paths.replicaPath(hubID),
            transportKind: .cloudKit,
            hubID: hubID,
            linkedDevice: linked ? device : nil,
            defaults: try makeDefaults(),
            recordingsDirectory: paths.recordingsDirectory(hubID),
            hold: RecordingHold(directory: paths.holdDirectory),
            uploadRetriesAllowed: true,
            makeRecorder: { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                    now: { clock.now }, tickInterval: nil
                )
            },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        addTeardownBlock { @MainActor in session.stop() }
        return Hub(session: session, transport: transport, clock: clock)
    }

    private func makeEnvironment(_ hubs: [Hub]) throws -> AppEnvironment {
        let env = AppEnvironment(transportKind: .cloudKit, defaults: try makeDefaults()) { _ in }
        for hub in hubs {
            env.add(hub.session)
        }
        if let first = hubs.first {
            env.activate(first.session.hubID)
        }
        return env
    }

    /// Records a 30 s voice note through the environment's recorder and
    /// returns the saved id.
    private func recordThroughEnvironment(_ env: AppEnvironment, clock: FakeClock) async throws -> String {
        await env.recorder.recordVoiceNote()
        clock.advance(30)
        let recorder = env.recorder
        await recorder.stop()
        return try XCTUnwrap(recorder.savedRecording?.id, "expected a saved recording")
    }

    /// A recording held for `hubID` (as a removal holds it): recorded by a
    /// throwaway session of that hub, on a replica of its own, then moved
    /// into the shared hold.
    private func holdRecording(for hubID: String, base: URL) async throws -> HeldRecording {
        let seed = try makeHub(hubID, base: base, linked: false, replicaPath: try makeReplicaPath())
        await seed.session.waitForBoot()
        await seed.session.recorder.recordVoiceNote()
        seed.clock.advance(30)
        await seed.session.recorder.stop()
        let id = try XCTUnwrap(seed.session.recorder.savedRecording?.id)
        let row = try XCTUnwrap(try seed.session.store.phoneRecording(id: id))
        let held = HeldRecording(row, marks: [], hubID: hubID, macName: nil)
        try RecordingHold(directory: paths(base).holdDirectory).hold([held], from: paths(base).recordingsDirectory(hubID))
        seed.session.stop()
        return held
    }

    // MARK: - Review Focus 5

    /// A capture started on hub A goes on under hub B, is stopped there,
    /// and is sent by A's uploader through A's transport only.
    func testARecordingStartedOnOneHubFinishesThereAfterASwitch() async throws {
        let base = try makeBase()
        let hubA = try makeHub("hub-a", base: base)
        let hubB = try makeHub("hub-b", base: base)
        let env = try makeEnvironment([hubA, hubB])
        await env.waitForBoot()

        await env.recorder.recordVoiceNote()
        XCTAssertTrue(env.recorder === hubA.session.recorder)
        env.activate("hub-b")

        XCTAssertTrue(env.recorder === hubA.session.recorder, "the running capture stays on screen")
        XCTAssertTrue(env.capturingSession === hubA.session)
        hubA.clock.advance(30)
        await env.recorder.stop()

        XCTAssertTrue(env.recorder === hubB.session.recorder, "the capture ended: the active hub's recorder")
        let id = try XCTUnwrap(hubA.session.recorder.savedRecording?.id)
        XCTAssertNotNil(try hubA.session.store.phoneRecording(id: id))
        XCTAssertNil(try hubB.session.store.phoneRecording(id: id))
        let uploadsA = try await relayUploads(in: hubA.transport)
        XCTAssertEqual(uploadsA.map(\.id), [id], "sent to the Mac it started on")
        let uploadsB = try await relayUploads(in: hubB.transport)
        XCTAssertTrue(uploadsB.isEmpty, "never sent to the hub on screen")
    }

    func testOneCaptureAtATimeAcrossHubs() async throws {
        let base = try makeBase()
        let hubA = try makeHub("hub-a", base: base)
        let hubB = try makeHub("hub-b", base: base)
        let env = try makeEnvironment([hubA, hubB])
        await env.waitForBoot()
        XCTAssertTrue(env.canStartCapture)
        XCTAssertNil(env.captureHubName)

        await env.recorder.recordVoiceNote()
        XCTAssertFalse(env.canStartCapture)
        XCTAssertNil(env.captureHubName, "a capture on the hub on screen names no Mac")
        hubA.session.hubName = "Acme Studio"
        env.activate("hub-b")

        XCTAssertFalse(env.canStartCapture, "hub B's Record buttons are off while hub A captures")
        XCTAssertEqual(env.captureHubName, "Acme Studio")
        // A Record tap on hub B reaches the running capture, never a second one.
        await env.recorder.recordVoiceNote()
        XCTAssertFalse(hubB.session.recorder.isCapturing)
        XCTAssertTrue(hubA.session.recorder.isCapturing)

        hubA.clock.advance(30)
        env.recorder.pause()
        XCTAssertFalse(env.canStartCapture, "a paused capture still holds the microphone")
        await hubA.session.recorder.stop()
        XCTAssertTrue(env.canStartCapture)
        XCTAssertNil(env.captureHubName)
    }

    func testTheRecordingsListShowsTheActiveHubsRecordings() async throws {
        let base = try makeBase()
        let hubA = try makeHub("hub-a", base: base)
        let hubB = try makeHub("hub-b", base: base)
        let env = try makeEnvironment([hubA, hubB])
        await env.waitForBoot()

        let onA = try await recordThroughEnvironment(env, clock: hubA.clock)
        env.activate("hub-b")
        let onB = try await recordThroughEnvironment(env, clock: hubB.clock)

        try await poll({ env.phoneRecordings.snapshot.recording(onB) != nil }, "hub B's recording not listed")
        XCTAssertNil(env.phoneRecordings.snapshot.recording(onA))
        env.activate("hub-a")
        try await poll({ env.phoneRecordings.snapshot.recording(onA) != nil }, "hub A's recording not listed")
        XCTAssertNil(env.phoneRecordings.snapshot.recording(onB))
    }

    /// The held list on a hub's Recordings shows the recordings waiting
    /// for a Mac the phone no longer has, and its own not yet adopted;
    /// never another linked hub's (that hub adopts them).
    func testTheHeldListNeverShowsAnotherLinkedHubsRecordings() async throws {
        let base = try makeBase()
        let forB = try await holdRecording(for: "hub-b", base: base)
        let forGone = try await holdRecording(for: "hub-gone", base: base)
        let hubA = try makeHub("hub-a", base: base)
        let env = try makeEnvironment([hubA])
        await env.waitForBoot()
        XCTAssertEqual(Set(env.heldRecordings.map(\.id)), [forB.id, forGone.id], "one hub: every other hub's waits here")

        let hubB = try makeHub("hub-b", base: base)
        env.add(hubB.session)
        _ = await hubB.session.adoption?.value

        XCTAssertEqual(env.heldRecordings.map(\.id), [forGone.id], "hub B's recording is hub B's, not on hub A's list")
        env.activate("hub-b")
        XCTAssertEqual(env.heldRecordings.map(\.id), [forGone.id])
    }

    // MARK: - Review Focus 3

    /// Both sessions adopt their own held recording from one manifest at
    /// one boot: each lands in its own replica and folder, none is lost,
    /// and the manifest ends empty.
    func testTwoSessionsAdoptTheirOwnHeldRecordingsAtOneBoot() async throws {
        let base = try makeBase()
        let forA = try await holdRecording(for: "hub-a", base: base)
        let forB = try await holdRecording(for: "hub-b", base: base)
        let hold = RecordingHold(directory: paths(base).holdDirectory)
        XCTAssertEqual(Set(try hold.load().map(\.id)), [forA.id, forB.id])

        let hubA = try makeHub("hub-a", base: base)
        let hubB = try makeHub("hub-b", base: base)
        async let adoptedA = hubA.session.adoption?.value
        async let adoptedB = hubB.session.adoption?.value
        let reports = await [adoptedA, adoptedB]

        XCTAssertEqual(reports, [HeldAdoption(), HeldAdoption()])
        XCTAssertEqual(try hubA.session.store.phoneRecordings().map(\.id), [forA.id])
        XCTAssertEqual(try hubB.session.store.phoneRecordings().map(\.id), [forB.id])
        let folderA = paths(base).recordingsDirectory("hub-a")
        let folderB = paths(base).recordingsDirectory("hub-b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderA.appendingPathComponent(forA.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderB.appendingPathComponent(forB.fileName).path))
        XCTAssertTrue(try hold.load().isEmpty, "both adoptions left the manifest")
        let env = try makeEnvironment([hubA, hubB])
        XCTAssertTrue(env.heldRecordings.isEmpty)
        env.activate("hub-b")
        XCTAssertTrue(env.heldRecordings.isEmpty)
    }
}
