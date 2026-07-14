import Foundation

/// App-wide registry for prefetching WhisperKit model files ahead of a
/// recording, so `MeetingRecorderCenter`'s engine load (at record-start, and
/// again at transcribe-time as a fallback) usually hits an already-warm
/// on-disk cache instead of paying for the download right when the user is
/// waiting on a transcript.
///
/// Decoupled from `MeetingRecorderCenter.Phase` on purpose: a recording never
/// depends on WhisperKit, so a download can be in flight (or failed) while a
/// recording is independently in progress — one state machine can't
/// represent both without an artificial precedence between them.
@MainActor
@Observable
final class TranscriptionModelProvisioner {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The model the current/last `ensureDownloaded` call targets. A stale
    /// call's progress/outcome is checked against this and dropped once a
    /// different model has been requested.
    private(set) var currentModelName: String?
    /// The model whose files are already confirmed on disk from a prior
    /// successful prefetch — re-requesting it is a no-op, so reopening the
    /// Calendar tab doesn't re-hit the network every time.
    private var lastSucceededModel: String?

    private(set) var currentTask: Task<Void, Never>?

    private let downloadFn: (String, @escaping @Sendable (Double) -> Void) async throws -> Void

    init(
        downloadFn: @escaping (String, @escaping @Sendable (Double) -> Void) async throws -> Void = { modelName, progress in
            _ = try await WhisperKitEngine.ensureModelFilesDownloaded(modelName: modelName, downloadProgress: progress)
        }
    ) {
        self.downloadFn = downloadFn
    }

    /// Starts (or joins) the download of `modelName`'s files. No-op if that
    /// exact model is already downloading or already succeeded. Supersedes
    /// any in-flight download of a different model — best-effort only: the
    /// superseded download may keep running in the background, but its
    /// progress/outcome is dropped once superseded.
    func ensureDownloaded(modelName: String) {
        if case .downloading = state, currentModelName == modelName {
            return
        }
        if case .idle = state, lastSucceededModel == modelName {
            return
        }

        currentTask?.cancel()
        currentModelName = modelName
        state = .downloading(progress: 0)

        currentTask = Task { [weak self, downloadFn] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<Double>.makeStream()
            let work = Task.detached {
                do {
                    try await downloadFn(modelName) { progress in continuation.yield(progress) }
                    continuation.finish()
                    return Result<Void, Error>.success(())
                } catch {
                    continuation.finish()
                    return .failure(error)
                }
            }
            for await progress in stream {
                guard self.currentModelName == modelName else { continue }
                self.state = .downloading(progress: progress)
            }
            guard self.currentModelName == modelName else { return }
            switch await work.value {
            case .success:
                self.lastSucceededModel = modelName
                self.state = .idle
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-attempts the download for the model that just failed. No-op unless
    /// `state` is `.failed`.
    func retry() {
        guard case .failed = state, let modelName = currentModelName else { return }
        ensureDownloaded(modelName: modelName)
    }

    /// Clears a `.failed` state without retrying — the next natural trigger
    /// (reopening Calendar, re-selecting the model in Settings) tries again.
    func dismiss() {
        guard case .failed = state else { return }
        state = .idle
    }
}
