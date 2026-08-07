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
/// tail (`contextPromptTail`), so context survives a failed window and short
/// silence just like language does — until `contextPromptSilenceLimit`
/// consecutive silent windows expire it.
/// If no window produces speech and at least one failed with an engine error,
/// the last engine error is thrown — total engine failure never masquerades
/// as an all-silence recording.
struct WindowedTranscriber {
    let engine: WhisperWindowEngine
    let config: TranscriptionConfig

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
        var promptState = ContextPromptState()
        var lastEngineError: Error?

        for (index, range) in ranges.enumerated() {
            let window = Array(samples[range])

            let language: String
            if let forced = config.forcedLanguage {
                language = forced
            } else {
                language = await resolveWindowLanguage(for: window, previous: prevLang, config: config, engine: engine)
            }

            let prompt = contextPromptTail(prevText: promptState.text, prevLang: prevLang, language: language, config: config)
            let rawSegments: [TranscribedSegment]
            do {
                rawSegments = try await engine.transcribeWindow(window, language: language, prompt: prompt)
            } catch {
                // A failed window is skipped: nothing counted, language does not stick.
                lastEngineError = error
                progress(index + 1, windowCount)
                continue
            }

            if let lifted = liftWindowSegments(rawSegments, windowStart: range.lowerBound, language: language) {
                texts.append(lifted.windowText)
                segments.append(contentsOf: lifted.segments)
                prevLang = language
                promptState.recordSpeech(lifted.windowText)
                langStats[language, default: 0] += 1
            } else {
                promptState.recordSilence()
            }
            progress(index + 1, windowCount)
        }

        // Total engine failure must not masquerade as "no speech": if no window
        // produced speech and at least one failed with an engine error, surface
        // the error. Genuine all-silence (no errors) still returns empty output.
        if texts.isEmpty, let lastEngineError {
            throw lastEngineError
        }

        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats, segments: segments)
    }
}
