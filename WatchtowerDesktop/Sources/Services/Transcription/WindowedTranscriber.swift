import Foundation

/// Direct port of snoop transcribe.py's windowing + sticky-language algorithm,
/// with window boundaries planned by `WindowPlanner` (silence-snapped cuts).
///
/// The audio is sliced into overlapping windows; each window's language is
/// detected (restricted to the configured langset) and accepted only when both
/// the confidence threshold and the margin over the runner-up are met —
/// otherwise it falls back to the previous *speech* window's language ("sticky"),
/// or to `firstWindowDefault` when no speech window has been produced yet.
/// Silent and failed windows never stick and are not counted in langStats.
/// Each window is decoded conditioned on the previous *speech* window's text
/// tail (`contextPromptTail`), so context survives a failed window just like
/// language does — but a silent window expires it
/// (`ContextPromptState.silenceLimit`; three with the speech gate off).
/// If no window produces speech and at least one failed with an engine error,
/// the last engine error is thrown — total engine failure never masquerades
/// as an all-silence recording.
/// With `speechDetector` set and `config.speechGate` on, `WindowSpeechGate`
/// skips windows without speech before language detection (they count as
/// silent windows) and drops decoded segments outside the detected speech.
struct WindowedTranscriber {
    let engine: WhisperWindowEngine
    let config: TranscriptionConfig
    var speechDetector: SpeechDetector?

    /// progress: (windowIndex, windowCount) after each window completes (1-based).
    func transcribe(samples: [Float],
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        guard !samples.isEmpty else {
            return TranscriptionOutput(text: "", langStats: [:])
        }

        let planner = WindowPlanner(config: config)
        let ranges = planner.planWindows(total: samples.count) { samples[$0] }
        let windowCount = ranges.count

        var texts: [String] = []
        var segments: [TranscriptSegment] = []
        var langStats: [String: Int] = [:]
        var prevLang: String?
        var promptState = ContextPromptState(speechGate: config.speechGate)
        var lastEngineError: Error?
        var gate = WindowSpeechGate(detector: speechDetector, config: config)
        defer { gate.logSummary() }

        for (index, range) in ranges.enumerated() {
            // A cancelled batch throws rather than returning the windows it
            // skipped as silence (the speech gate reads a cancelled detector
            // call as a silent window).
            try Task.checkCancellation()
            let decoded = await decodeGatedWindow(Array(samples[range]), gate: &gate, previousLanguage: prevLang,
                                                  promptText: promptState.text, config: config, engine: engine)
            switch decoded {
            case let .failed(error):
                // A failed window is skipped: nothing counted, language does not stick.
                lastEngineError = error
            case let .decoded(rawSegments, language):
                if let lifted = liftWindowSegments(rawSegments, windowStart: range.lowerBound, language: language) {
                    texts.append(lifted.windowText)
                    segments.append(contentsOf: lifted.segments)
                    prevLang = language
                    promptState.recordSpeech(lifted.windowText)
                    langStats[language, default: 0] += 1
                } else {
                    promptState.recordSilence()
                }
            case .silent:
                promptState.recordSilence()
            }
            progress(index + 1, windowCount)
        }

        // Total engine failure must not masquerade as "no speech": if no window
        // produced speech and at least one failed with an engine error, surface
        // the error. Genuine all-silence (no errors) still returns empty output.
        try Task.checkCancellation()
        if texts.isEmpty, let lastEngineError {
            throw lastEngineError
        }

        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats, segments: segments)
    }
}
