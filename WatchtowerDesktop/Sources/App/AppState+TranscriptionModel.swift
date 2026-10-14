import Foundation
import WatchtowerCore

extension AppState {
    /// How often a download waiting for the first sync asks again.
    private static let firstSyncRecheck: Duration = .seconds(15)

    /// The model a meeting recording loads: Settings' engine and model.
    var meetingModelKey: TranscriptionModelProvisioner.ModelKey? {
        TranscriptionModelProvisioner.ModelKey(id: MeetingRecorderCenter.defaultEngineKey())
    }

    /// Downloads the meeting model ahead of use when the Meetings goal is
    /// chosen (`TranscriptionModelAutoDownload`, #744): at launch, when
    /// onboarding or a re-run finishes, and when the Calendar opens. It
    /// waits for the first sync to finish first, so the model's gigabyte does
    /// not compete with it; without the goal nothing downloads until the
    /// first recording or dictation. A call while one waits is a no-op.
    func autoDownloadTranscriptionModel() {
        guard transcriptionModelAutoDownload == nil else { return }
        let startedAt = Date()
        transcriptionModelAutoDownload = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let key = self.meetingModelKey else { return }
                let decision = TranscriptionModelAutoDownload.decide(
                    goals: self.onboardingGoals.savedGoals,
                    onboardingComplete: !self.needsOnboarding,
                    modelOnDisk: self.transcriptionModelProvisioner.isDownloaded(key),
                    firstSyncFinished: DaemonManager.readLastSyncTime() != nil,
                    waited: Date().timeIntervalSince(startedAt)
                )
                switch decision {
                case .download:
                    self.transcriptionModelProvisioner.ensureDownloaded(key, purpose: .meetings)
                    self.transcriptionModelAutoDownload = nil
                    return
                case .skip:
                    self.transcriptionModelAutoDownload = nil
                    return
                case .waitForFirstSync:
                    try? await Task.sleep(for: Self.firstSyncRecheck)
                }
            }
        }
    }
}
