import Foundation

/// App-wide owner of in-flight meeting-notes generation, living on AppState
/// so the "generating…" state survives navigation (view-local state would
/// lose the flag when the user leaves the recording and comes back — the CLI
/// keeps running and persists notes_md regardless; this center keeps the UI
/// truthful about it).
@MainActor
@Observable
final class TranscriptNotesCenter {
    private(set) var generating: Set<Int64> = []
    private(set) var lastError: [Int64: String] = [:]

    /// Starts notes generation for a transcript. No-op when a run for the
    /// same transcript is already in flight. `onFinished` fires on success
    /// AND failure — callers reload notes_md from the DB (the CLI is the
    /// writer).
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
                _ = try await service.generateNotes(transcriptID: transcriptID)
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
