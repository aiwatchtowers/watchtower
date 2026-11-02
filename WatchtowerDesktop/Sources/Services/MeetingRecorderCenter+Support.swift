import Foundation

// Small pieces of `MeetingRecorderCenter` kept out of its main file (its
// length cap): the default recordings folder, the no-speech message and a
// job phase's failure.

extension MeetingRecorderCenter {
    /// `nonisolated` so it can serve as the init's default argument (evaluated
    /// outside the main actor); it only reads `FileManager`.
    nonisolated static func defaultRecordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/recordings", isDirectory: true)
    }

    /// Why a recording yielded no text. A bare "No speech recognized" hid
    /// the usual cause: the call's audio never reached the recording (the
    /// activity sidecar's system channel is silent throughout or went
    /// silent and stayed so), leaving only a quiet room microphone.
    nonisolated static func noSpeechMessage(_ activity: MicActivity?) -> String {
        guard let activity else { return "No speech recognized" }
        var watch = CallAudioWatch(binSec: MicActivity.binDuration)
        activity.bins.forEach { watch.add(system: $0.sys) }
        if watch.neverHeardCall {
            return "No speech recognized — no call audio was captured at all. If this was a call, \(callAudioOutputHint)"
        }
        if let gap = watch.openGap {
            return "No speech recognized — call audio stopped at \(TranscriptFormatting.formatTimecode(gap.startSec)) "
                + "and never came back — \(callAudioOutputHint)"
        }
        return "No speech recognized"
    }
}

extension MeetingRecorderCenter.ProcessingJob.Phase {
    var isFailed: Bool { failureMessage != nil }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
