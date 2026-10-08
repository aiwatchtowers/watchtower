import AVFoundation
import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A clock the tests move by hand: the recorder reads time only through it.
@MainActor
final class FakeClock {
    private(set) var now: Date

    init(_ start: Date = Date()) {
        now = start
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// An audio engine that records nothing: `begin` writes a small stand-in
/// file, and every call is counted. `fileDuration` is what the "file"
/// plays (nil: unreadable), `holdFinish` keeps `finish` suspended until
/// `releaseFinish()`, and `fail(_:)` reports a dead capture.
@MainActor
final class FakeAudioEngine: AudioCaptureEngine {
    var onFailure: (@MainActor (String) -> Void)?
    var permissionGranted = true
    var levelValue: Float = 0.5
    var fileDuration: TimeInterval?
    var holdFinish = false
    private(set) var begunURLs: [URL] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var finishCount = 0
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool {
        permissionGranted
    }

    func begin(url: URL) throws {
        begunURLs.append(url)
        try Data(repeating: 0x5A, count: 256).write(to: url)
    }

    func pause() {
        pauseCount += 1
    }

    func resume() throws {
        resumeCount += 1
    }

    func finish() async {
        finishCount += 1
        if holdFinish {
            await withCheckedContinuation { finishWaiter = $0 }
        }
    }

    func releaseFinish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    func level() -> Float {
        levelValue
    }

    func recordedDuration(of url: URL) async -> TimeInterval? {
        fileDuration
    }

    func fail(_ message: String) {
        onFailure?(message)
    }
}

/// One recorder over fakes: no audio, no ticker, a hand-moved clock.
@MainActor
struct RecorderRig {
    let controller: PhoneRecorderController
    let engine: FakeAudioEngine
    let clock: FakeClock
    let store: ReplicaStore
    let transport: InMemoryCloudTransport
    let notifications: NotificationCenter
    let directory: URL
}

extension XCTestCase {
    /// A temp directory for recordings, removed on teardown.
    func makeRecordingsDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A recorder over fakes. Pass `sharing:` to build the "relaunched" app
    /// over an earlier rig's replica, transport and directory.
    @MainActor
    func makeRecorderRig(
        deviceID: String? = "device-a",
        sharing earlier: RecorderRig? = nil,
        tickInterval: Duration? = nil
    ) throws -> RecorderRig {
        let store = try earlier?.store ?? ReplicaStore.inMemory()
        let transport = earlier?.transport ?? InMemoryCloudTransport()
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let notifications = NotificationCenter()
        let directory = try earlier?.directory ?? makeRecordingsDirectory()
        let controller = PhoneRecorderController(
            uploader: RecordingUploader(transport: transport, store: store, deviceID: deviceID),
            engine: engine,
            directory: directory,
            notificationCenter: notifications,
            now: { clock.now },
            tickInterval: tickInterval
        )
        return RecorderRig(
            controller: controller, engine: engine, clock: clock, store: store,
            transport: transport, notifications: notifications, directory: directory
        )
    }

    /// The `recording_upload` records in the relay zone, decoded.
    func relayUploads(in transport: any CloudSyncTransport) async throws -> [RecordingUploadPayload] {
        let batch = try await transport.changes(in: .relay, since: nil)
        return try batch.changed
            .filter { $0.kind == RelayRecordKind.recordingUpload.rawValue }
            .map { try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: $0.payload) }
    }

    /// Posts an `AVAudioSession` interruption the way the system does.
    func postInterruption(_ center: NotificationCenter, began: Bool, shouldResume: Bool = true) {
        var info: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: (began ? AVAudioSession.InterruptionType.began : .ended).rawValue
        ]
        if !began, shouldResume {
            info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        }
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }
}
