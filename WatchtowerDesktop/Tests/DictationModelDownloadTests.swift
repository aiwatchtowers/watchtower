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

    func testFirstDictationShowsTheDownloadAndLoadsOnceItLands() async throws {
        let defaults = try whisperDefaults()
        var releaseDownload: CheckedContinuation<Void, Never>?
        var downloads = 0
        let models = TranscriptionModelProvisioner(
            downloadFn: { _, _, progress in
                downloads += 1
                progress(0.4)
                await withCheckedContinuation { releaseDownload = $0 }
            },
            describe: { _ in (label: "Whisper small", sizeBytes: 490_000_000) },
            defaults: defaults)
        var engineLoads = 0
        let center = DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["hello"]), supportsLive: true)
            },
            appleSupported: { false },
            runnerResolver: { FakeCLIRunner(stdout: Data()) },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        center.modelProvisioner = models

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("the download to report progress") {
            if case .downloading(progress: 0.4) = center.modelDownload?.state { return true }
            return false
        }
        XCTAssertEqual(center.modelDownload?.key, smallKey)
        XCTAssertEqual(engineLoads, 0, "the engine must not load before its model is on disk")
        XCTAssertEqual(DictationButton.loadingText(center.modelDownload), "Downloading model… 40%")

        releaseDownload?.resume()
        await waitUntil("the engine to load") { !center.isEngineLoading }
        XCTAssertEqual(engineLoads, 1)
        XCTAssertEqual(downloads, 1)
        XCTAssertNil(center.modelDownload, "a loaded engine has no download to show")
        XCTAssertEqual(DictationButton.loadingText(nil), "Loading model…")
        center.cancel()
    }

    func testAFailedDownloadFailsTheDictationInPlainWords() async throws {
        let defaults = try whisperDefaults()
        let models = TranscriptionModelProvisioner(
            downloadFn: { _, _, _ in throw URLError(.notConnectedToInternet) },
            describe: { _ in (label: "Whisper small", sizeBytes: nil) },
            defaults: defaults)
        var engineLoads = 0
        let center = DictationCenter(
            recorderFactory: { FakeMicRecorder() },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["hello"]), supportsLive: true)
            },
            appleSupported: { false },
            runnerResolver: { FakeCLIRunner(stdout: Data()) },
            defaults: defaults,
            engineIdleTTL: .seconds(900)
        )
        center.modelProvisioner = models

        center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
        await waitUntil("the dictation to fail") {
            if case .failed = center.phase { return true }
            return false
        }
        guard case let .failed(message) = center.phase else { return XCTFail("expected .failed") }
        XCTAssertTrue(message.contains("connection dropped"), message)
        XCTAssertEqual(engineLoads, 0)
        XCTAssertNotNil(models.download(for: smallKey), "the failed download stays on screen with Retry")
    }
}
