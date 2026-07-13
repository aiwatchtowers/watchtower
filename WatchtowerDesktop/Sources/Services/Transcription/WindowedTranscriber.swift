import Foundation

/// Direct port of snoop transcribe.py's windowing + sticky-language algorithm.
///
/// The audio is sliced into overlapping windows; each window's language is
/// detected (restricted to the configured langset) and accepted only when both
/// the confidence threshold and the margin over the runner-up are met —
/// otherwise it falls back to the previous *speech* window's language ("sticky"),
/// or to `firstWindowDefault` when no speech window has been produced yet.
/// Silent and failed windows never stick and are not counted in langStats.
struct WindowedTranscriber {
    let engine: TranscriptionEngine
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

        var starts: [Int] = []
        var start = 0
        while start < samples.count {
            starts.append(start)
            start += step
        }
        let windowCount = starts.count

        var texts: [String] = []
        var langStats: [String: Int] = [:]
        var prevLang: String?

        for (index, windowStart) in starts.enumerated() {
            let end = min(windowStart + windowSamples, samples.count)
            let window = Array(samples[windowStart..<end])

            let language: String
            if let forced = config.forcedLanguage {
                language = forced
            } else {
                language = await chooseLanguage(for: window, previous: prevLang)
            }

            let text: String
            do {
                text = try await engine.transcribeWindow(window, language: language)
            } catch {
                // A failed window is skipped: nothing counted, language does not stick.
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

        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats)
    }

    /// Detection with sticky fallback. A detection error is treated as low
    /// confidence (fallback), never fatal.
    private func chooseLanguage(for window: [Float], previous: String?) async -> String {
        let fallback = previous ?? config.firstWindowDefault
        guard let probs = try? await engine.detectLanguage(window) else {
            return fallback
        }
        let restricted = probs
            .filter { config.langset.contains($0.key) }
            .sorted { $0.value > $1.value }
        guard let best = restricted.first else { return fallback }
        let runnerUp = restricted.dropFirst().first?.value ?? 0
        if best.value >= config.langThreshold && (best.value - runnerUp) >= config.margin {
            return best.key
        }
        return fallback
    }
}
