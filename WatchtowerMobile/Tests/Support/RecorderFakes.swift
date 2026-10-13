import AVFoundation
import Foundation
import UIKit
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
/// plays (`unclamped` by default, so the recorded time decides; nil:
/// unreadable), `holdFinish` keeps `finish` suspended until
/// `releaseFinish()`, `resumeError` makes `resume` throw, and `fail(_:)`
/// reports a dead capture. `sessionActive` follows the audio session the
/// real engine holds: active from `begin` to `pause`/`finish`, again after
/// `resume`.
@MainActor
final class FakeAudioEngine: AudioCaptureEngine {
    var onFailure: (@MainActor (String) -> Void)?
    var permissionGranted = true
    var levelValue: Float = 0.5
    static let unclamped: TimeInterval = 1_000_000_000
    var fileDuration: TimeInterval? = FakeAudioEngine.unclamped
    var holdFinish = false
    /// Keeps `requestPermission` suspended until `releasePermission()`.
    var holdPermission = false
    private var permissionWaiter: CheckedContinuation<Void, Never>?
    var resumeError: (any Error)?
    private(set) var begunURLs: [URL] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var finishCount = 0
    private(set) var sessionActive = false
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool {
        if holdPermission {
            await withCheckedContinuation { permissionWaiter = $0 }
        }
        return permissionGranted
    }

    /// Answers a permission request `holdPermission` kept waiting.
    func releasePermission() {
        permissionWaiter?.resume()
        permissionWaiter = nil
    }

    func begin(url: URL) throws {
        begunURLs.append(url)
        try Data(repeating: 0x5A, count: 256).write(to: url)
        sessionActive = true
    }

    func pause() {
        pauseCount += 1
        sessionActive = false
    }

    func resume() throws {
        if let resumeError { throw resumeError }
        resumeCount += 1
        sessionActive = true
    }

    func finish() async {
        finishCount += 1
        sessionActive = false
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

/// Records the background tasks begun and ended; `expire()` runs the
/// latest expiration handler the way iOS does.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskRunning {
    private(set) var begun: [String] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expiration: (@MainActor () -> Void)?
    /// False: iOS grants no time and `begin` returns `.invalid`.
    var grantsTime = true

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        begun.append(name)
        guard grantsTime else { return .invalid }
        self.expiration = expiration
        return UIBackgroundTaskIdentifier(rawValue: begun.count)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        ended.append(task)
    }

    func expire() {
        expiration?()
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
    /// The paired phone over `transport`: the uploader's, and the one that
    /// reads its sealed uploads back.
    let secure: SecureTransport
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
    /// over an earlier rig's replica, transport and directory. `uploadClock`
    /// is the uploader's clock (its retry backoff), `sleep` the wait behind
    /// the long-pause auto-finish (by default it never ends), `store` a
    /// replica of the test's own (an in-memory one by default).
    @MainActor
    func makeRecorderRig(
        deviceID: String? = "device-a",
        sharing earlier: RecorderRig? = nil,
        store givenStore: ReplicaStore? = nil,
        directory movedDirectory: URL? = nil,
        tickInterval: Duration? = nil,
        uploadClock: MutableClock? = nil,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) throws -> RecorderRig {
        let store = try givenStore ?? earlier?.store ?? TestPhone.replica()
        let transport = earlier?.transport ?? InMemoryCloudTransport()
        let secure = try earlier?.secure ?? TestPhone.transport(over: transport)
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let notifications = NotificationCenter()
        let directory = try movedDirectory ?? earlier?.directory ?? makeRecordingsDirectory()
        // The default auto-finish wait never ends by itself (no test waits
        // out an hour) and is cancelled on teardown, so no parked task
        // outlives the test.
        let parked = TickSleeper()
        addTeardownBlock { @MainActor in parked.cancelAll() }
        let uploader = RecordingUploader(
            transport: secure, store: store, directory: directory, deviceID: deviceID
        ) { uploadClock?.now ?? Date() }
        let controller = PhoneRecorderController(
            uploader: uploader,
            engine: engine,
            notificationCenter: notifications,
            now: { clock.now },
            tickInterval: tickInterval,
            sleep: sleep ?? { try await parked.sleep($0) }
        )
        return RecorderRig(
            controller: controller, engine: engine, clock: clock, store: store,
            transport: transport, secure: secure, notifications: notifications, directory: directory
        )
    }

    /// The `recording_upload` records in the relay zone, opened as the
    /// paired phone and decoded.
    func relayUploads(
        in transport: any CloudSyncTransport & Sendable, _ pairing: TestPhone.Pairing = .test
    ) async throws -> [RecordingUploadPayload] {
        let batch = try await TestPhone.transport(over: transport, pairing).changes(in: .relay, since: nil)
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
