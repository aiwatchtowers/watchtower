import Foundation
import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// `DictationCenter` with the model provisioner wired (#744): a first
/// dictation on a Whisper model waits for that model's download, shows it,
/// and a failed download fails the dictation in plain words.
@MainActor
final class DictationModelDownloadTests: MeetingRecorderTestCase {
    private let smallKey = TranscriptionModelProvisioner.ModelKey(providerID: "whisperkit", model: "small")

    private func whisperDefaults() throws -> UserDefaults {
        let defaults = try isolatedDefaults()
        defaults.set("small", forKey: DictationEngineChoice.defaultsKey)
        defaults.set("en", forKey: "transcription.forceLang")
        return defaults
    }

    private func center(
        _ models: TranscriptionModelProvisioner,
        defaults: UserDefaults,
        engineLoads: @escaping @MainActor () -> Void
    ) -> DictationCenter {
        let center = DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in
                await engineLoads()
                return TestTranscriber(ScriptedEngine(texts: ["hello"]), supportsLive: true)
            },
            appleSupported: { false },
            runnerResolver: { FakeCLIRunner(stdout: Data()) },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        center.modelProvisioner = models
        return center
    }

    func testFirstDictationShowsTheDownloadAndLoadsOnceItLands() async throws {
        let defaults = try whisperDefaults()
        let download = HeldDownload()
        let models = TranscriptionModelProvisioner.forTests(download, defaults: defaults, label: "Whisper small")
        var engineLoads = 0
        let center = center(models, defaults: defaults) { engineLoads += 1 }

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("the download to be held") { download.isHeld }
        await waitUntil("the download to report progress") {
            center.modelDownload?.state == .downloading(progress: 0.25)
        }
        XCTAssertEqual(center.modelDownload?.key, smallKey)
        XCTAssertEqual(engineLoads, 0, "the engine must not load before its model is on disk")
        XCTAssertEqual(DictationButton.loadingText(center.modelDownload), "Downloading model… 25%")

        download.finish()
        await waitUntil("the engine to load") { !center.isEngineLoading }
        XCTAssertEqual(engineLoads, 1)
        XCTAssertEqual(download.calls, 1)
        XCTAssertNil(center.modelDownload, "a loaded engine has no download to show")
        XCTAssertEqual(DictationButton.loadingText(nil), "Loading model…")
        center.cancel()
    }

    /// Cancelling a first dictation mid-download stops waiting at once — no
    /// engine load, nothing left on the capsule — while the download carries
    /// on, and the next dictation finds the model on disk.
    func testCancelDuringTheDownloadLeavesTheDownloadRunning() async throws {
        let defaults = try whisperDefaults()
        let download = HeldDownload()
        let models = TranscriptionModelProvisioner.forTests(download, defaults: defaults)
        var engineLoads = 0
        let center = center(models, defaults: defaults) { engineLoads += 1 }

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("the download to be held") { download.isHeld }
        center.cancel()
        await waitUntil("the dictation to settle") { center.phase == .idle }
        XCTAssertFalse(center.isEngineLoading)
        XCTAssertNil(center.modelDownload)
        XCTAssertNotNil(models.download(for: smallKey), "the download keeps going")

        download.finish()
        await waitUntil("the download to land") { models.isDownloaded(self.smallKey) }
        XCTAssertEqual(engineLoads, 0)

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("the second dictation's engine") { !center.isEngineLoading }
        XCTAssertEqual(engineLoads, 1)
        XCTAssertEqual(download.calls, 1, "the second dictation needs no download")
        center.cancel()
    }

    func testAFailedDownloadFailsTheDictationInPlainWords() async throws {
        let defaults = try whisperDefaults()
        let download = HeldDownload()
        let models = TranscriptionModelProvisioner.forTests(download, defaults: defaults)
        var engineLoads = 0
        let center = center(models, defaults: defaults) { engineLoads += 1 }

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("the download to be held") { download.isHeld }
        download.failWith = URLError(.notConnectedToInternet)
        download.finish()
        await waitUntil("the dictation to fail") {
            if case .failed = center.phase { return true }
            return false
        }
        guard case let .failed(message) = center.phase else { return XCTFail("expected .failed") }
        XCTAssertTrue(message.hasPrefix("The connection dropped"), message)
        XCTAssertEqual(engineLoads, 0)
        XCTAssertNotNil(models.download(for: smallKey), "the failed download stays on screen with Retry")
    }
}
