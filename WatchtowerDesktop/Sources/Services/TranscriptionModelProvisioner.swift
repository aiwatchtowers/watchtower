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
    /// The provider the current/last `ensureDownloaded` call targets. A stale
    /// call's progress/outcome is checked against this (alongside
    /// `currentModelName`) and dropped once a different (provider, model)
    /// pair has been requested.
    private(set) var currentProviderID: String?
    /// The model the current/last `ensureDownloaded` call targets. A stale
    /// call's progress/outcome is checked against this and dropped once a
    /// different model has been requested.
    private(set) var currentModelName: String?
    /// The (provider, model) pair whose files are already confirmed on disk
    /// from a prior successful prefetch — re-requesting it is a no-op, so
    /// reopening the Calendar tab doesn't re-hit the network every time.
    private var lastSucceededProviderID: String?
    private var lastSucceededModel: String?

    private(set) var currentTask: Task<Void, Never>?

    private let downloadFn: (String, String, @escaping @Sendable (Double) -> Void) async throws -> Void

    init(
        downloadFn: @escaping (String, String, @escaping @Sendable (Double) -> Void) async throws -> Void = { providerID, model, progress in
            let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
            try await provider.prefetch(model: model, progress: progress)
        }
    ) {
        self.downloadFn = downloadFn
    }

    /// Starts (or joins) the download of `model`'s files for `providerID`.
    /// No-op if that exact (provider, model) pair is already downloading or
    /// already succeeded. Supersedes any in-flight download of a different
    /// pair — best-effort only: the superseded download may keep running in
    /// the background, but its progress/outcome is dropped once superseded.
    func ensureDownloaded(providerID: String, model: String) {
        if case .downloading = state, currentProviderID == providerID, currentModelName == model {
            return
        }
        if case .idle = state, lastSucceededProviderID == providerID, lastSucceededModel == model {
            return
        }

        currentTask?.cancel()
        currentProviderID = providerID
        currentModelName = model
        state = .downloading(progress: 0)

        currentTask = Task { [weak self, downloadFn] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<Double>.makeStream()
            let work = Task.detached {
                do {
                    try await downloadFn(providerID, model) { progress in continuation.yield(progress) }
                    continuation.finish()
                    return Result<Void, Error>.success(())
                } catch {
                    continuation.finish()
                    return .failure(error)
                }
            }
            for await progress in stream {
                guard self.currentProviderID == providerID, self.currentModelName == model else { continue }
                self.state = .downloading(progress: progress)
            }
            guard self.currentProviderID == providerID, self.currentModelName == model else { return }
            switch await work.value {
            case .success:
                self.lastSucceededProviderID = providerID
                self.lastSucceededModel = model
                self.state = .idle
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-attempts the download for the (provider, model) pair that just
    /// failed. No-op unless `state` is `.failed`.
    func retry() {
        guard case .failed = state, let providerID = currentProviderID, let model = currentModelName else { return }
        ensureDownloaded(providerID: providerID, model: model)
    }

    /// Clears a `.failed` state without retrying — the next natural trigger
    /// (reopening Calendar, re-selecting the model in Settings) tries again.
    func dismiss() {
        guard case .failed = state else { return }
        state = .idle
    }
}
