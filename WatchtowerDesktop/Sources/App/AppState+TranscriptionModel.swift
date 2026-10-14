import Foundation
import WatchtowerCore

extension AppState {
    /// Diarizer models are prefetched only while speaker roles are on, the
    /// speech-gate VAD model only while the gate is on; a failure is fine —
    /// the post-pass retries the diarizer download and degrades to a
    /// role-less transcript, the gate retries its download per recording and
    /// falls back to the energy detector.
    @Sendable static func prefetchDiarizerModels() async {
        let config = TranscriptionConfig.fromDefaults()
        if config.diarization {
            try? await FluidAudioDiarizer.prefetchModels()
        }
        if config.speechGate {
            try? await SileroSpeechDetector.prefetchModel()
        }
    }

    /// Both load paths wait for their model's download through the one
    /// provisioner (#744).
    func wireTranscriptionModelDownloads() {
        meetingRecorderCenter.modelProvisioner = transcriptionModelProvisioner
        dictationCenter.modelProvisioner = transcriptionModelProvisioner
    }

    /// The model a meeting recording loads: Settings' engine and model.
    var meetingModelKey: TranscriptionModelProvisioner.ModelKey? {
        TranscriptionModelProvisioner.ModelKey(id: MeetingRecorderCenter.defaultEngineKey())
    }

    /// Downloads the meeting model ahead of use when the Meetings goal is
    /// chosen (`TranscriptionModelAutoDownloader`, #744): at launch, when
    /// onboarding or a re-run finishes, and when the Calendar opens.
    func autoDownloadTranscriptionModel() {
        transcriptionModelAutoDownloader.askAndDownload()
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
