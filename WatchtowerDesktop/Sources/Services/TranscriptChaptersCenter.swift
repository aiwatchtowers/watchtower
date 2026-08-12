import Foundation
import WatchtowerCore

/// App-wide owner of in-flight meeting-chapters generation, living on
/// AppState so the "generating…" state survives navigation (the
/// TranscriptNotesCenter pattern: view-local state would lose the flag when
/// the user leaves the recording and comes back — the CLI keeps running and
/// persists chapters_json regardless; this center keeps the UI truthful).
@MainActor
@Observable
final class TranscriptChaptersCenter {
    private(set) var generating: Set<Int64> = []
    private(set) var lastError: [Int64: String] = [:]

    /// Starts chapters generation for a transcript. No-op when a run for the
    /// same transcript is already in flight. `onFinished` fires on success
    /// AND failure — callers reload chapters_json from the DB (the CLI is
    /// the writer).
    func generate(
        transcriptID: Int64,
        service: TranscriptSaveService,
        onFinished: @escaping @MainActor () -> Void
    ) {
        guard !generating.contains(transcriptID) else { return }
        generating.insert(transcriptID)
        lastError[transcriptID] = nil
        Task {
            do {
                _ = try await service.generateChapters(transcriptID: transcriptID)
            } catch {
                lastError[transcriptID] = error.localizedDescription
            }
            generating.remove(transcriptID)
            onFinished()
        }
    }

    func clearError(transcriptID: Int64) {
        lastError[transcriptID] = nil
    }
}
