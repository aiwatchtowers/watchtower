import Foundation

/// Private recordings (MEETPRIV, docs/features/private-meetings.md): the
/// flag the indicator's lock changes before a recording is saved.
extension MeetingRecorderCenter {
    /// Best-effort, but logged: a lost write only matters after a crash,
    /// when the recovered recording would save with the old flag. A flip
    /// that found no row is re-applied by `beginPending`'s caller and
    /// written by `persistTranscript` with the job's flag.
    func persistPrivate(_ isPrivate: Bool, for audioURL: URL) async {
        let name = audioURL.lastPathComponent
        guard let store = pendingStore else {
            print("[MeetingRecorder] no pending store: the private flag of \(name) is kept in memory only")
            return
        }
        do {
            if try await !store.setPrivate(recording: name, isPrivate) {
                print("[MeetingRecorder] the private flag of \(name) found no pending row yet")
            }
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
