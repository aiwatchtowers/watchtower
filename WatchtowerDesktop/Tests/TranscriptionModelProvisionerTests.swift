import XCTest
@testable import WatchtowerDesktop

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
        lock.lock()
        callCount += 1
        calledModels.append(modelName)
        calledProviders.append(providerID)
        lock.unlock()
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
    var errorDescription: String? { "network unreachable" }
}

// MARK: - Tests

@MainActor
final class TranscriptionModelProvisionerTests: XCTestCase {

    /// Drains the main actor so the provisioner's stream-backed state updates
    /// (yielded from the detached download task) have been applied.
    private func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }

    func testDownloadingReportsProgressThenIdleOnSuccess() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        var entered = downloader.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        await drainMainActor()

        guard case .downloading(let progress) = provisioner.state else {
            return XCTFail("expected .downloading, got \(provisioner.state)")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.0001)

        downloader.release("large-v3")
        await provisioner.currentTask?.value

        XCTAssertEqual(provisioner.state, .idle)
        XCTAssertEqual(downloader.calledModels, ["large-v3"])
    }

    func testSameModelWhileDownloadingIsANoOp() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        var entered = downloader.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        await drainMainActor()

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")

        XCTAssertEqual(downloader.callCount, 1, "a duplicate request for the same in-flight model must be a no-op")

        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testDifferentModelSupersedesInFlightDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        _ = await entered.next()
        await drainMainActor()
        let staleTask = provisioner.currentTask

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "distil-large-v3")
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(downloader.calledModels, ["large-v3", "distil-large-v3"])
        guard case .downloading = provisioner.state else {
            return XCTFail("expected .downloading for the new model, got \(provisioner.state)")
        }

        // The stale large-v3 call finishing later must not resurrect its outcome.
        downloader.release("large-v3")
        await staleTask?.value
        await drainMainActor()
        guard case .downloading = provisioner.state else {
            return XCTFail(".downloading for the current model must survive the stale download completing, got \(provisioner.state)")
        }

        downloader.release("distil-large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    /// Closes a Task-4 review minor: provider-switching is now user-reachable
    /// (the Settings Engine picker), so the OTHER half of the pair-identity
    /// check — a different provider with the SAME model name — needs its own
    /// coverage alongside `testDifferentModelSupersedesInFlightDownload`'s
    /// same-provider/different-model case.
    func testDifferentProviderSameModelSupersedesInFlightDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        _ = await entered.next()
        await drainMainActor()
        let staleTask = provisioner.currentTask

        provisioner.ensureDownloaded(providerID: "apple", model: "large-v3")
        _ = await entered.next()
        await drainMainActor()

        XCTAssertEqual(downloader.calledProviders, ["whisperkit", "apple"])
        guard case .downloading = provisioner.state else {
            return XCTFail("expected .downloading for the new provider, got \(provisioner.state)")
        }

        // The stale whisperkit call finishing later must not resurrect its outcome.
        downloader.release("large-v3", providerID: "whisperkit")
        await staleTask?.value
        await drainMainActor()
        guard case .downloading = provisioner.state else {
            return XCTFail(".downloading for the current provider must survive the stale download completing, got \(provisioner.state)")
        }

        downloader.release("large-v3", providerID: "apple")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testFailureSurfacesMessageAndRetryReDownloadsSameModel() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        _ = await entered.next()
        await drainMainActor()

        downloader.release("large-v3", error: FakeDownloadError())
        await provisioner.currentTask?.value

        guard case .failed(let message) = provisioner.state else {
            return XCTFail("expected .failed, got \(provisioner.state)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("network unreachable"))

        provisioner.retry()
        _ = await entered.next()
        await drainMainActor()
        guard case .downloading = provisioner.state else {
            return XCTFail("retry must re-download the same model, got \(provisioner.state)")
        }
        XCTAssertEqual(downloader.calledModels, ["large-v3", "large-v3"])

        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testDismissClearsFailedStateWithoutRetrying() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        _ = await entered.next()
        await drainMainActor()

        downloader.release("large-v3", error: FakeDownloadError())
        await provisioner.currentTask?.value

        guard case .failed = provisioner.state else {
            return XCTFail("expected .failed, got \(provisioner.state)")
        }

        provisioner.dismiss()
        XCTAssertEqual(provisioner.state, .idle)
        XCTAssertEqual(downloader.callCount, 1, "dismiss must not trigger a retry")
    }

    func testAlreadySucceededModelIsNotReDownloaded() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")
        _ = await entered.next()
        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)

        // e.g. reopening the Calendar tab after the model already downloaded.
        provisioner.ensureDownloaded(providerID: "whisperkit", model: "large-v3")

        XCTAssertEqual(downloader.callCount, 1, "re-requesting an already-downloaded model must not re-trigger a download")
    }
}
