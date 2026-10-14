import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

// MARK: - Fakes

/// Blocks each `call` until the test releases it (keyed by model name, so two
/// models can be in flight at once — e.g. a superseded download and the one
/// that replaced it). Signals entry via `enteredStream` so tests can
/// deterministically observe state at each step without racing the async work.
private final class GateDownloader: @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var calledModels: [String] = []
    private(set) var calledProviders: [String] = []
    let enteredStream: AsyncStream<String>

    private let enteredContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    // Keyed by "providerID|modelName" so a same-model call under a different
    // provider (the supersede-by-provider test) blocks/releases independently
    // instead of colliding with the other provider's in-flight continuation.
    private var pendingContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var queuedResults: [String: Result<Void, Error>] = [:]

    init() {
        (enteredStream, enteredContinuation) = AsyncStream<String>.makeStream()
    }

    private func key(_ providerID: String, _ modelName: String) -> String { "\(providerID)|\(modelName)" }

    func call(providerID: String, modelName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let k = key(providerID, modelName)
        lock.withLock {
            callCount += 1
            calledModels.append(modelName)
            calledProviders.append(providerID)
        }
        enteredContinuation.yield(modelName)
        progress(0.5)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let queued = queuedResults.removeValue(forKey: k) {
                lock.unlock()
                continuation.resume(with: queued)
            } else {
                pendingContinuations[k] = continuation
                lock.unlock()
            }
        }
    }

    /// Lets the currently-blocked (or next) call for `modelName` under
    /// `providerID` (default "whisperkit", matching every pre-existing test's
    /// single-provider usage) return.
    func release(_ modelName: String, providerID: String = "whisperkit", error: Error? = nil) {
        let k = key(providerID, modelName)
        lock.lock()
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        if let continuation = pendingContinuations.removeValue(forKey: k) {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            queuedResults[k] = result
            lock.unlock()
        }
    }
}

private struct FakeDownloadError: Error, LocalizedError {
    var errorDescription: String? { "server said no" }
}

/// A library error that wraps the transport failure, the way the model
/// hub's `networkError(URLError)` does.
private enum WrappingHubError: Error {
    case networkError(URLError)
}

// MARK: - Tests

/// The model-download registry (#744): background downloads, first-use
/// `prepare` (joining a running download, failure, retry, cancellation),
/// supersede by purpose, and the on-disk marker a launch reads.
@MainActor
final class TranscriptionModelProvisionerTests: XCTestCase {
    private typealias Key = TranscriptionModelProvisioner.ModelKey
    private let large = Key(providerID: "whisperkit", model: "large-v3")
    private let distil = Key(providerID: "whisperkit", model: "distil-large-v3")
    private let small = Key(providerID: "whisperkit", model: "small")
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TranscriptionModelProvisionerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeProvisioner(_ downloader: GateDownloader,
                                 now: @escaping () -> Date = Date.init) -> TranscriptionModelProvisioner {
        TranscriptionModelProvisioner(
            downloadFn: downloader.call,
            describe: { key in (label: "Model \(key.model)", sizeBytes: 1_600_000_000) },
            defaults: defaults,
            now: now)
    }

    /// Drains the main actor so the provisioner's stream-backed state updates
    /// (yielded from the detached download task) have been applied.
    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func state(_ provisioner: TranscriptionModelProvisioner, _ key: Key) -> TranscriptionModelProvisioner.State? {
        provisioner.download(for: key)?.state
    }

    func testDownloadingReportsProgressThenLeavesTheListAndMarksTheModelOnDisk() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(state(provisioner, large), .downloading(progress: 0.5))
        XCTAssertEqual(provisioner.download(for: large)?.label, "Model large-v3")
        XCTAssertFalse(provisioner.isDownloaded(large))

        downloader.release("large-v3")
        await provisioner.task(for: large)?.value

        XCTAssertTrue(provisioner.downloads.isEmpty, "a finished download leaves the list")
        XCTAssertTrue(provisioner.isDownloaded(large))
        XCTAssertEqual(defaults.stringArray(forKey: TranscriptionModelProvisioner.downloadedModelsKey),
                       ["whisperkit|large-v3"])
    }

    func testSameModelWhileDownloadingIsANoOp() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        provisioner.ensureDownloaded(large)
        provisioner.ensureDownloaded(large, purpose: .dictation)

        XCTAssertEqual(downloader.callCount, 1, "a duplicate request for the same in-flight model must be a no-op")
        downloader.release("large-v3")
        await provisioner.task(for: large)?.value
        XCTAssertTrue(provisioner.downloads.isEmpty)
    }

    func testDifferentModelOfTheSamePurposeSupersedesTheRunningDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        let staleTask = provisioner.task(for: large)

        provisioner.ensureDownloaded(distil)
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(downloader.calledModels, ["large-v3", "distil-large-v3"])
        XCTAssertEqual(provisioner.downloads.map(\.key), [distil], "the superseded download leaves the list")

        // The stale call finishing later must not resurrect its outcome.
        downloader.release("large-v3")
        await staleTask?.value
        await drainMainActor()
        XCTAssertFalse(provisioner.isDownloaded(large), "a superseded download's success is dropped")
        XCTAssertEqual(provisioner.downloads.map(\.key), [distil])

        downloader.release("distil-large-v3")
        await provisioner.task(for: distil)?.value
        XCTAssertTrue(provisioner.isDownloaded(distil))
    }

    /// The other half of the pair identity: a different provider with the
    /// SAME model name is a different download.
    func testDifferentProviderSameModelSupersedesTheRunningDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()
        let apple = Key(providerID: "apple", model: "large-v3")

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        provisioner.ensureDownloaded(apple)
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(downloader.calledProviders, ["whisperkit", "apple"])
        XCTAssertEqual(provisioner.downloads.map(\.key), [apple])

        downloader.release("large-v3", providerID: "whisperkit")
        downloader.release("large-v3", providerID: "apple")
        await provisioner.task(for: apple)?.value
        XCTAssertTrue(provisioner.isDownloaded(apple))
        XCTAssertFalse(provisioner.isDownloaded(large))
    }

    /// The meeting model and the dictation model are different downloads
    /// for different surfaces: one never cancels the other.
    func testMeetingAndDictationDownloadsRunSideBySide() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large, purpose: .meetings)
        _ = await entered.next()
        provisioner.ensureDownloaded(small, purpose: .dictation)
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(Set(provisioner.downloads.map(\.key)), [large, small])
        downloader.release("small")
        downloader.release("large-v3")
        await provisioner.task(for: small)?.value
        await provisioner.task(for: large)?.value
        XCTAssertTrue(provisioner.isDownloaded(small))
        XCTAssertTrue(provisioner.isDownloaded(large))
    }

    func testNetworkFailureSaysSoAndRetryDownloadsAgain() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        downloader.release("large-v3", error: WrappingHubError.networkError(URLError(.networkConnectionLost)))
        await provisioner.task(for: large)?.value

        guard case let .failed(message) = state(provisioner, large) else {
            return XCTFail("expected .failed, got \(String(describing: state(provisioner, large)))")
        }
        XCTAssertTrue(message.contains("connection dropped"), message)

        provisioner.retry(large)
        _ = await entered.next()
        await drainMainActor()
        XCTAssertEqual(state(provisioner, large), .downloading(progress: 0.5), "retry must download the same model again")
        XCTAssertEqual(downloader.calledModels, ["large-v3", "large-v3"])

        downloader.release("large-v3")
        await provisioner.task(for: large)?.value
        XCTAssertTrue(provisioner.isDownloaded(large))
    }

    func testDismissClearsAFailureWithoutRetrying() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        downloader.release("large-v3", error: FakeDownloadError())
        await provisioner.task(for: large)?.value
        guard case let .failed(message) = state(provisioner, large) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(message, "Couldn't download the model: server said no")

        provisioner.dismiss(large)
        XCTAssertTrue(provisioner.downloads.isEmpty)
        XCTAssertEqual(downloader.callCount, 1, "dismiss must not trigger a retry")
    }

    /// A launch reads the marker instead of the network: a model a previous
    /// run downloaded is neither re-downloaded nor waited on.
    func testAModelOnDiskIsNotDownloadedAgainAcrossLaunches() async throws {
        let downloader = GateDownloader()
        let first = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()
        first.ensureDownloaded(large)
        _ = await entered.next()
        downloader.release("large-v3")
        await first.task(for: large)?.value

        let relaunched = makeProvisioner(downloader)
        XCTAssertTrue(relaunched.isDownloaded(large))
        relaunched.ensureDownloaded(large)
        try await relaunched.prepare(large, purpose: .meetings)

        XCTAssertEqual(downloader.callCount, 1, "a model on disk must not be downloaded again")
        XCTAssertTrue(relaunched.downloads.isEmpty)
    }

    /// First use while the background download is already running: the
    /// engine load joins it — one download — and goes on once it lands.
    func testFirstUseJoinsTheRunningDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large, purpose: .meetings)
        _ = await entered.next()

        var prepared = false
        let firstUse = Task { @MainActor in
            try await provisioner.prepare(large, purpose: .meetings)
            prepared = true
        }
        await drainMainActor()
        XCTAssertFalse(prepared, "the load must wait for the download")

        downloader.release("large-v3")
        try await firstUse.value
        XCTAssertTrue(prepared)
        XCTAssertEqual(downloader.callCount, 1, "joining must not start a second download")
    }

    /// First use with nothing downloaded starts the download itself, shows
    /// it, and a failed attempt is retried by the next use.
    func testFirstUseDownloadsFailsInPlainWordsAndTheNextUseRetries() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        let firstUse = Task { @MainActor in try await provisioner.prepare(small, purpose: .dictation) }
        _ = await entered.next()
        await drainMainActor()
        XCTAssertEqual(state(provisioner, small), .downloading(progress: 0.5), "first use shows its download")

        downloader.release("small", error: URLError(.notConnectedToInternet))
        do {
            try await firstUse.value
            XCTFail("a failed download must fail the load")
        } catch let failure as TranscriptionModelProvisioner.DownloadFailed {
            XCTAssertTrue(failure.message.contains("connection dropped"), failure.message)
        }

        let secondUse = Task { @MainActor in try await provisioner.prepare(small, purpose: .dictation) }
        _ = await entered.next()
        downloader.release("small")
        try await secondUse.value
        XCTAssertEqual(downloader.callCount, 2)
        XCTAssertTrue(provisioner.isDownloaded(small))
    }

    /// A cancelled first use (a dictation cancelled mid-download) stops
    /// waiting at once; the download itself carries on.
    func testCancelledFirstUseStopsWaitingButTheDownloadContinues() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        let firstUse = Task { @MainActor in try await provisioner.prepare(small, purpose: .dictation) }
        _ = await entered.next()
        await drainMainActor()
        firstUse.cancel()
        do {
            try await firstUse.value
            XCTFail("a cancelled wait must throw")
        } catch is CancellationError {}

        XCTAssertEqual(state(provisioner, small), .downloading(progress: 0.5))
        downloader.release("small")
        await provisioner.task(for: small)?.value
        XCTAssertTrue(provisioner.isDownloaded(small))
    }

    /// A Settings switch never breaks a recording waiting on its model.
    func testADownloadAFirstUseWaitsOnIsNotSuperseded() async throws {
        let downloader = GateDownloader()
        let provisioner = makeProvisioner(downloader)
        var entered = downloader.enteredStream.makeAsyncIterator()

        let firstUse = Task { @MainActor in try await provisioner.prepare(large, purpose: .meetings) }
        _ = await entered.next()
        await drainMainActor()
        provisioner.ensureDownloaded(distil, purpose: .meetings)
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(Set(provisioner.downloads.map(\.key)), [large, distil])
        downloader.release("large-v3")
        downloader.release("distil-large-v3")
        try await firstUse.value
        XCTAssertTrue(provisioner.isDownloaded(large))
    }

    /// The time left counts from the first progress report (`startFraction`),
    /// so a resumed download does not claim its resumed part was fetched just
    /// now; with no progress since then there is no guess at all.
    func testProgressLineCarriesSizeAndPercentAndNoGuessWithoutProgress() async throws {
        let downloader = GateDownloader()
        var clock = Date()
        let provisioner = makeProvisioner(downloader) { clock }
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(large)
        _ = await entered.next()
        await drainMainActor()
        let download = try XCTUnwrap(provisioner.download(for: large))
        XCTAssertEqual(download.startFraction, 0.5)
        XCTAssertEqual(download.progressLine(now: clock), "Downloading Model large-v3 — 50% of about \(ModelDownloadText.size(1_600_000_000))",
                       "no time left before there is progress to measure")

        clock = clock.addingTimeInterval(10)
        XCTAssertNil(download.secondsLeft(now: clock), "no progress since the start: no estimate")

        downloader.release("large-v3")
        await provisioner.task(for: large)?.value
    }
}
