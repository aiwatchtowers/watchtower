import Foundation

/// Direct port of snoop transcribe.py's windowing + sticky-language algorithm.
///
/// The audio is sliced into overlapping windows; each window's language is
/// detected (restricted to the configured langset) and accepted only when both
/// the confidence threshold and the margin over the runner-up are met —
/// otherwise it falls back to the previous *speech* window's language ("sticky"),
/// or to `firstWindowDefault` when no speech window has been produced yet.
/// Silent and failed windows never stick and are not counted in langStats.
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

        let sampleRate = Double(TranscriptionConfig.sampleRate)
        let windowSamples = max(1, Int(config.windowSec * sampleRate))
        let step = max(1, windowSamples - Int(config.overlapSec * sampleRate))

        // A window reaching the end of the samples is the last one: a further
        // tail start would lie entirely inside this window's overlap and only
        // duplicate its audio (and lang stats).
        var starts: [Int] = []
        var start = 0
        while true {
            starts.append(start)
            if start + windowSamples >= samples.count { break }
            start += step
        }
        let windowCount = starts.count

        var texts: [String] = []
        var langStats: [String: Int] = [:]
        var prevLang: String?
        var lastEngineError: Error?

        for (index, windowStart) in starts.enumerated() {
            let end = min(windowStart + windowSamples, samples.count)
            let window = Array(samples[windowStart..<end])

            let language: String
            if let forced = config.forcedLanguage {
                language = forced
            } else {
                language = await resolveWindowLanguage(for: window, previous: prevLang, config: config, engine: engine)
            }

            let text: String
            do {
                text = try await engine.transcribeWindow(window, language: language)
            } catch {
                // A failed window is skipped: nothing counted, language does not stick.
                lastEngineError = error
                progress(index + 1, windowCount)
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                texts.append(trimmed)
                prevLang = language
                langStats[language, default: 0] += 1
            }
            progress(index + 1, windowCount)
        }

        // Total engine failure must not masquerade as "no speech": if no window
        // produced speech and at least one failed with an engine error, surface
        // the error. Genuine all-silence (no errors) still returns empty output.
        if texts.isEmpty, let lastEngineError {
            throw lastEngineError
        }

        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats)
    }
}
