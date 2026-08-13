import Foundation
import WatchtowerCore

/// App-wide owner of in-flight "Suggest speaker names" runs and their
/// results, living on AppState so the "guessing…" state and the returned
/// suggestion chips survive navigating away from the recording and back
/// (async ops need navigation-surviving state — the TranscriptNotesCenter
/// pattern). Suggestions are ephemeral per-transcript state: never persisted,
/// dropped when a suggestion is confirmed/dismissed or a new run replaces
/// them.
@MainActor
@Observable
final class SpeakerGuessCenter {
    private(set) var generating: Set<Int64> = []
    private(set) var lastError: [Int64: String] = [:]
    /// Informational outcome of a successful run that produced nothing to
    /// confirm — presented as info, never with the failure styling.
    private(set) var lastNotice: [Int64: String] = [:]
    private(set) var suggestions: [Int64: [SpeakerSuggestion]] = [:]

    /// Starts a speaker-guess run for a transcript. No-op when a run for the
    /// same transcript is already in flight. `onFinished` fires on success
    /// AND failure so views can refresh their state.
    func suggest(
        transcriptID: Int64,
        service: TranscriptSaveService,
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        guard !generating.contains(transcriptID) else { return }
        generating.insert(transcriptID)
        lastError[transcriptID] = nil
        lastNotice[transcriptID] = nil
        Task {
            do {
                let result = try await service.speakerGuess(transcriptID: transcriptID)
                suggestions[transcriptID] = result.suggestions
                if result.suggestions.isEmpty {
                    lastNotice[transcriptID] = "No confident name suggestions for this recording"
                }
            } catch {
                lastError[transcriptID] = error.localizedDescription
            }
            generating.remove(transcriptID)
            onFinished()
        }
    }

    /// Drops one speaker's chip after it was confirmed (the rename applied)
    /// or explicitly dismissed.
    func consumeSuggestion(transcriptID: Int64, speaker: String) {
        suggestions[transcriptID]?.removeAll { $0.speaker == speaker }
        if suggestions[transcriptID]?.isEmpty == true {
            suggestions[transcriptID] = nil
        }
    }

    func clearError(transcriptID: Int64) {
        lastError[transcriptID] = nil
        lastNotice[transcriptID] = nil
    }
}
