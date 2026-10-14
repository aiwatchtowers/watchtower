import Foundation
import WatchtowerCore

/// Downloads the meeting model ahead of use when the Meetings goal is
/// chosen (#744). It asks `TranscriptionModelAutoDownload.decide` and, while
/// the very first sync runs, asks again every `recheck` until it may start
/// or the cap runs out. An `askAndDownload()` while one is waiting is a no-op, so the
/// cap counts from the first trigger. Without the goal nothing downloads
/// until the first recording or dictation.
@MainActor
final class TranscriptionModelAutoDownloader {
    /// What the verdict reads, fresh on every ask — a re-run that drops the
    /// Meetings goal while the download waits stops it.
    struct Inputs {
        var goals: @MainActor () -> Set<OnboardingGoal>
        var onboardingComplete: @MainActor () -> Bool
        /// The model a meeting recording would load; nil for a Settings value
        /// that names none.
        var modelKey: @MainActor () -> TranscriptionModelProvisioner.ModelKey?
        var firstSyncFinished: @MainActor () -> Bool
    }

    static let recheck: Duration = .seconds(15)

    private let inputs: Inputs
    private let provisioner: TranscriptionModelProvisioner
    private let sleep: (Duration) async -> Void
    private let now: () -> Date

    /// The ask in progress (waiting for the first sync); nil when none.
    private(set) var pendingRun: Task<Void, Never>?

    init(
        inputs: Inputs,
        provisioner: TranscriptionModelProvisioner,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.inputs = inputs
        self.provisioner = provisioner
        self.sleep = sleep
        self.now = now
    }

    func askAndDownload() {
        guard pendingRun == nil else { return }
        let startedAt = now()
        pendingRun = Task { [weak self] in
            defer { self?.pendingRun = nil }
            while !Task.isCancelled {
                guard let self else { return }
                guard let key = inputs.modelKey() else {
                    print("[ModelDownload] no meeting model in Settings; nothing to download ahead of use")
                    return
                }
                let decision = TranscriptionModelAutoDownload.decide(
                    goals: inputs.goals(),
                    onboardingComplete: inputs.onboardingComplete(),
                    modelOnDisk: provisioner.isConfirmedOnDisk(key),
                    firstSyncFinished: inputs.firstSyncFinished(),
                    waited: now().timeIntervalSince(startedAt)
                )
                switch decision {
                case .download:
                    provisioner.ensureDownloaded(key, purpose: .meetings)
                    return
                case .skip:
                    return
                case .waitForFirstSync:
                    await sleep(Self.recheck)
                }
            }
        }
    }
}
