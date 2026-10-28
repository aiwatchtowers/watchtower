import Foundation

/// Private recordings (MEETPRIV, docs/features/private-meetings.md): the
/// flag the indicator's lock changes before a recording is saved.
extension MeetingRecorderCenter {
    /// Best-effort, but logged: a lost write only matters after a crash,
    /// when the recovered recording would save with the old flag.
    func persistPrivate(_ isPrivate: Bool, for audioURL: URL) async {
        do {
            try await pendingStore?.setPrivate(recording: audioURL.lastPathComponent, isPrivate)
        } catch {
            print("[MeetingRecorder] could not keep the private flag of \(audioURL.lastPathComponent): "
                  + error.localizedDescription)
        }
    }
}

extension MeetingRecorderCenter.ProcessingJob {
    /// The private flag can change until the save starts (`.summarizing`).
    var canChangePrivate: Bool { phase != .summarizing }
}
