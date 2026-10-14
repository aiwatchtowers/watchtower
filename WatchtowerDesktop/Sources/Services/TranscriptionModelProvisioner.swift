import Foundation
import WatchtowerCore

/// App-wide registry of transcription-model downloads, so a download is
/// visible (model, size, percent, time left) and retryable from anywhere —
/// the recording indicator, the tray, the dictation capsule — independent of
/// whether a recording is in progress.
///
/// Two ways in (#744): `ensureDownloaded` starts a download in the
/// background (Settings' model pickers, the Meetings goal's download ahead
/// of use); `prepare` is what an engine load awaits on first use — it joins
/// a download already running for the same model rather than starting a
/// second one, and throws the download's failure in plain words.
///
/// Decoupled from `MeetingRecorderCenter.Phase` on purpose: a recording never
/// depends on the model, so a download can be in flight (or failed) while a
/// recording is independently in progress.
@MainActor
@Observable
final class TranscriptionModelProvisioner {
    /// A (provider, model) pair. `id` is "provider|model" — the same string
    /// `MeetingRecorderCenter.defaultEngineKey` produces.
    struct ModelKey: Hashable, Sendable {
        let providerID: String
        let model: String

        var id: String { "\(providerID)|\(model)" }

        init(providerID: String, model: String) {
            self.providerID = providerID
            self.model = model
        }

        /// nil for a string that is not "provider|model".
        init?(id: String) {
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            self.init(providerID: parts[0], model: parts[1])
        }
    }

    /// Which surface a download serves. A new background request supersedes
    /// a running download of the same purpose only (a Settings switch drops
    /// the model it replaced); the meeting and dictation models download side
    /// by side.
    enum Purpose: Sendable {
        case meetings
        case dictation
    }

    enum State: Equatable {
        case downloading(progress: Double)
        case failed(String)
    }

    /// One download on screen: running or failed (a finished one leaves the
    /// list).
    struct Download: Identifiable, Equatable {
        let key: ModelKey
        let purpose: Purpose
        let label: String
        let sizeBytes: Int64?
        var state: State
        let startedAt: Date
        /// The first progress reported, so a resumed download's time left
        /// counts from where it resumed.
        var startFraction: Double?

        var id: String { key.id }

        func secondsLeft(now: Date) -> TimeInterval? {
            guard case let .downloading(progress) = state, let startFraction else { return nil }
            return ModelDownloadText.secondsLeft(startFraction: startFraction, startedAt: startedAt,
                                                 fraction: progress, now: now)
        }

        func progressLine(now: Date) -> String {
            guard case let .downloading(progress) = state else { return "Model download failed" }
            return ModelDownloadText.progressLine(model: label, sizeBytes: sizeBytes, fraction: progress,
                                                  secondsLeft: secondsLeft(now: now))
        }
    }

    /// The model failed to download; `message` is the owner-facing line.
    struct DownloadFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Running and failed downloads, oldest request first.
    private(set) var downloads: [Download] = []

    /// UserDefaults key of the "provider|model" ids confirmed on disk by a
    /// finished download — a launch asks this instead of the network.
    static let downloadedModelsKey = "transcription.downloadedModels"

    private var downloaded: Set<String>
    /// Per running download: its generation (a superseded or restarted
    /// download's late progress and outcome are dropped against it), the
    /// work, and the first-use callers waiting on it.
    private var running: [ModelKey: Running] = [:]

    private struct Running {
        let generation: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private let downloadFn: (String, String, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let describe: (ModelKey) -> (label: String, sizeBytes: Int64?)
    private let downloadsModel: (ModelKey) -> Bool
    private let filesMissing: (ModelKey) -> Bool
    /// Extra best-effort warmups run after a meeting model downloaded (e.g.
    /// diarizer models). No progress, failures swallowed by the closure itself.
    private let prefetchExtras: @Sendable () async -> Void
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        downloadFn: @escaping (String, String, @escaping @Sendable (Double) -> Void) async throws -> Void = { providerID, model, progress in
            let provider = TranscriptionProviderRegistry.resolve(providerID: providerID)
            try await provider.prefetch(model: model, progress: progress)
        },
        describe: @escaping (ModelKey) -> (label: String, sizeBytes: Int64?) = TranscriptionModelProvisioner.describe,
        downloadsModel: @escaping (ModelKey) -> Bool = {
            TranscriptionProviderRegistry.resolve(providerID: $0.providerID).downloadsModel
        },
        filesMissing: @escaping (ModelKey) -> Bool = {
            TranscriptionProviderRegistry.resolve(providerID: $0.providerID).modelFilesMissing(model: $0.model)
        },
        prefetchExtras: @escaping @Sendable () async -> Void = {},
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.downloadFn = downloadFn
        self.describe = describe
        self.downloadsModel = downloadsModel
        self.filesMissing = filesMissing
        self.prefetchExtras = prefetchExtras
        self.defaults = defaults
        self.now = now
        downloaded = Set(defaults.stringArray(forKey: Self.downloadedModelsKey) ?? [])
    }

    /// The registry's label and size for a model; dictation's Whisper
    /// variants are not in the meeting picker, so they fall back to
    /// "Whisper <model>".
    static func describe(_ key: ModelKey) -> (label: String, sizeBytes: Int64?) {
        let provider = TranscriptionProviderRegistry.resolve(providerID: key.providerID)
        let label = provider.models.first { $0.id == key.model }?.label ?? "Whisper \(key.model)"
        return (label, provider.downloadSizeBytes(model: key.model))
    }

    /// Whether a load can go ahead without a download: the engine ships no
    /// model of ours, or the model is on disk.
    func isDownloaded(_ key: ModelKey) -> Bool {
        !downloadsModel(key) || isConfirmedOnDisk(key)
    }

    /// A finished download recorded the model, and its files are still
    /// there (or the provider cannot tell). The files are looked at only for
    /// a recorded model — never, for an owner who never transcribed, in a
    /// folder macOS guards — and a cache deleted by hand downloads again,
    /// with its progress, instead of silently inside an engine load.
    private func isConfirmedOnDisk(_ key: ModelKey) -> Bool {
        downloaded.contains(key.id) && !filesMissing(key)
    }

    func download(for key: ModelKey) -> Download? {
        downloads.first { $0.key == key }
    }

    /// Starts the download of `key` in the background. No-op when it is
    /// already running or already on disk. A failed attempt starts over (the
    /// libraries resume partly downloaded files). Supersedes a running
    /// download of another model with the same purpose unless a first use is
    /// waiting on it.
    func ensureDownloaded(_ key: ModelKey, purpose: Purpose = .meetings) {
        guard running[key] == nil, !isConfirmedOnDisk(key) else { return }
        for other in downloads where other.key != key && other.purpose == purpose {
            guard running[other.key]?.waiters.isEmpty ?? true else { continue }
            running.removeValue(forKey: other.key)?.task.cancel()
            downloads.removeAll { $0.key == other.key }
        }
        let info = describe(key)
        let download = Download(key: key, purpose: purpose, label: info.label, sizeBytes: info.sizeBytes,
                                state: .downloading(progress: 0), startedAt: now())
        if let index = downloads.firstIndex(where: { $0.key == key }) {
            downloads[index] = download
        } else {
            downloads.append(download)
        }
        let generation = UUID()
        running[key] = Running(generation: generation, task: startTask(key, generation: generation, purpose: purpose))
    }

    /// Convenience for the Settings pickers.
    func ensureDownloaded(providerID: String, model: String, purpose: Purpose = .meetings) {
        ensureDownloaded(ModelKey(providerID: providerID, model: model), purpose: purpose)
    }

    /// Awaited before a first-use engine load: returns at once when the
    /// model is on disk, otherwise starts (or joins) its download and returns
    /// when it lands. Throws `DownloadFailed` when it fails, and
    /// `CancellationError` when the caller is cancelled — the download itself
    /// keeps going.
    func prepare(_ key: ModelKey, purpose: Purpose) async throws {
        if isDownloaded(key) { return }
        ensureDownloaded(key, purpose: purpose)
        guard running[key] != nil else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, running[key] != nil else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                running[key]?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.running[key]?.waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Re-attempts a failed download.
    func retry(_ key: ModelKey) {
        guard let download = download(for: key), case .failed = download.state else { return }
        ensureDownloaded(key, purpose: download.purpose)
    }

    /// Clears a failed download without retrying — the next trigger (a
    /// recording, Settings) tries again.
    func dismiss(_ key: ModelKey) {
        guard let download = download(for: key), case .failed = download.state else { return }
        downloads.removeAll { $0.key == key }
    }

    /// Test hook: the running download's task, awaited to let it settle.
    func task(for key: ModelKey) -> Task<Void, Never>? {
        running[key]?.task
    }

    // MARK: - Private

    private func startTask(_ key: ModelKey, generation: UUID, purpose: Purpose) -> Task<Void, Never> {
        Task { [weak self, downloadFn] in
            let (stream, continuation) = AsyncStream<Double>.makeStream()
            let work = Task.detached {
                do {
                    try await downloadFn(key.providerID, key.model) { progress in continuation.yield(progress) }
                    continuation.finish()
                    return Result<Void, Error>.success(())
                } catch {
                    continuation.finish()
                    return .failure(error)
                }
            }
            await withTaskCancellationHandler {
                for await progress in stream {
                    self?.apply(progress: progress, to: key, generation: generation)
                }
                let result = await work.value
                self?.finish(key, generation: generation, purpose: purpose, result: result)
            } onCancel: {
                work.cancel()
            }
        }
    }

    private func isCurrent(_ key: ModelKey, _ generation: UUID) -> Bool {
        running[key]?.generation == generation
    }

    private func apply(progress: Double, to key: ModelKey, generation: UUID) {
        guard isCurrent(key, generation), let index = downloads.firstIndex(where: { $0.key == key }) else { return }
        downloads[index].state = .downloading(progress: progress)
        if downloads[index].startFraction == nil {
            downloads[index].startFraction = progress
        }
    }

    private func finish(_ key: ModelKey, generation: UUID, purpose: Purpose, result: Result<Void, Error>) {
        guard isCurrent(key, generation), let done = running.removeValue(forKey: key) else { return }
        switch result {
        case .success:
            downloads.removeAll { $0.key == key }
            downloaded.insert(key.id)
            defaults.set(downloaded.sorted(), forKey: Self.downloadedModelsKey)
            done.waiters.values.forEach { $0.resume() }
            // Fire-and-forget: extras (diarizer models) must never wedge or
            // fail THIS state machine — a hung/failed warmup just means the
            // post-pass pays for the download at Stop instead.
            if purpose == .meetings {
                Task.detached { [prefetchExtras] in await prefetchExtras() }
            }
        case .failure(let error):
            // The pill shows a plain sentence; the full error goes to the log.
            print("[ModelDownload] \(key.id) failed: \(String(reflecting: error))")
            let sizeBytes = downloads.first { $0.key == key }?.sizeBytes
            let failure = DownloadFailed(message: ModelDownloadText.failureMessage(for: error, sizeBytes: sizeBytes))
            if let index = downloads.firstIndex(where: { $0.key == key }) {
                downloads[index].state = .failed(failure.message)
            }
            done.waiters.values.forEach { $0.resume(throwing: failure) }
        }
    }
}
