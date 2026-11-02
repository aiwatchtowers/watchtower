import Foundation

// Small pieces of `MeetingRecorderCenter` kept out of its main file (its
// length cap): the default recordings folder and a job phase's failure.

extension MeetingRecorderCenter {
    /// `nonisolated` so it can serve as the init's default argument (evaluated
    /// outside the main actor); it only reads `FileManager`.
    nonisolated static func defaultRecordingsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/recordings", isDirectory: true)
    }
}

extension MeetingRecorderCenter.ProcessingJob.Phase {
    var isFailed: Bool { failureMessage != nil }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
