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
    let enteredStream: AsyncStream<String>

    private let enteredContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var pendingContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var queuedResults: [String: Result<Void, Error>] = [:]

    init() {
        (enteredStream, enteredContinuation) = AsyncStream<String>.makeStream()
    }

    func call(modelName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.lock()
        callCount += 1
        calledModels.append(modelName)
        lock.unlock()
        enteredContinuation.yield(modelName)
        progress(0.5)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let queued = queuedResults.removeValue(forKey: modelName) {
                lock.unlock()
                continuation.resume(with: queued)
            } else {
                pendingContinuations[modelName] = continuation
                lock.unlock()
            }
        }
    }

    /// Lets the currently-blocked (or next) call for `modelName` return.
    func release(_ modelName: String, error: Error? = nil) {
        lock.lock()
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        if let continuation = pendingContinuations.removeValue(forKey: modelName) {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            queuedResults[modelName] = result
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

        provisioner.ensureDownloaded(modelName: "large-v3")
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

        provisioner.ensureDownloaded(modelName: "large-v3")
        var entered = downloader.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        await drainMainActor()

        provisioner.ensureDownloaded(modelName: "large-v3")

        XCTAssertEqual(downloader.callCount, 1, "a duplicate request for the same in-flight model must be a no-op")

        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)
    }

    func testDifferentModelSupersedesInFlightDownload() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(modelName: "large-v3")
        _ = await entered.next()
        await drainMainActor()
        let staleTask = provisioner.currentTask

        provisioner.ensureDownloaded(modelName: "distil-large-v3")
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

    func testFailureSurfacesMessageAndRetryReDownloadsSameModel() async throws {
        let downloader = GateDownloader()
        let provisioner = TranscriptionModelProvisioner(downloadFn: downloader.call)
        var entered = downloader.enteredStream.makeAsyncIterator()

        provisioner.ensureDownloaded(modelName: "large-v3")
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

        provisioner.ensureDownloaded(modelName: "large-v3")
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

        provisioner.ensureDownloaded(modelName: "large-v3")
        _ = await entered.next()
        downloader.release("large-v3")
        await provisioner.currentTask?.value
        XCTAssertEqual(provisioner.state, .idle)

        // e.g. reopening the Calendar tab after the model already downloaded.
        provisioner.ensureDownloaded(modelName: "large-v3")

        XCTAssertEqual(downloader.callCount, 1, "re-requesting an already-downloaded model must not re-trigger a download")
    }
}
