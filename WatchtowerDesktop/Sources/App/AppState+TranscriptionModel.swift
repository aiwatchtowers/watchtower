import Foundation
import WatchtowerCore

extension AppState {
    /// The model a meeting recording loads: Settings' engine and model.
    var meetingModelKey: TranscriptionModelProvisioner.ModelKey? {
        TranscriptionModelProvisioner.ModelKey(id: MeetingRecorderCenter.defaultEngineKey())
    }

    /// Downloads the meeting model ahead of use when the Meetings goal is
    /// chosen (`TranscriptionModelAutoDownloader`, #744): at launch, when
    /// onboarding or a re-run finishes, and when the Calendar opens.
    func autoDownloadTranscriptionModel() {
        transcriptionModelAutoDownloader.run()
    }

    func makeTranscriptionModelAutoDownloader() -> TranscriptionModelAutoDownloader {
        TranscriptionModelAutoDownloader(
            inputs: .init(
                goals: { [weak self] in self?.onboardingGoals.savedGoals ?? [] },
                onboardingComplete: { [weak self] in self.map { !$0.needsOnboarding } ?? false },
                modelKey: { [weak self] in self?.meetingModelKey },
                // `last_sync.json` lands at the end of the daemon's first
                // Slack pass; a workspace without Slack never writes it and
                // waits out the cap.
                firstSyncFinished: { DaemonManager.readLastSyncTime() != nil }
            ),
            provisioner: transcriptionModelProvisioner
        )
    }
}
