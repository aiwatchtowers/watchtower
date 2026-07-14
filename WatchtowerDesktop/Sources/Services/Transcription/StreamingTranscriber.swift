import Foundation

/// One finished (speech) window emitted by the live transcriber.
struct StreamChunk: Equatable, Sendable {
    let index: Int      // 1-based over speech chunks
    let text: String
    let language: String
}

/// Live counterpart to `WindowedTranscriber`: consumes a running sample stream
/// and produces the SAME windowing/sticky-language result incrementally.
///
/// A window at absolute offset `start` is a "full, non-last" window as soon as
/// strictly more than `start + windowSamples` samples have arrived (i.e. there
/// is at least one sample beyond it — exactly `WindowedTranscriber`'s condition
/// for NOT breaking). The one remaining window at stream close is the last one,
/// truncated to the total length — matching the batch "exact-window-length is a
/// single window" rule. Silent/failed windows never stick and are not counted;
/// total engine failure throws rather than masquerading as all-silence.
struct StreamingTranscriber {
    let engine: TranscriptionEngine
    let config: TranscriptionConfig

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        let sampleRate = Double(TranscriptionConfig.sampleRate)
        let windowSamples = max(1, Int(config.windowSec * sampleRate))
        let step = max(1, windowSamples - Int(config.overlapSec * sampleRate))

        var buffer: [Float] = []      // buffer[0] is absolute sample `consumedBase`
        var consumedBase = 0
        var absStart = 0

        var texts: [String] = []
        var langStats: [String: Int] = [:]
        var prevLang: String?
        var lastEngineError: Error?
        var chunkIndex = 0

        func process(window: [Float]) async {
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
                lastEngineError = error
                return // skip: not counted, language does not stick
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            texts.append(trimmed)
            prevLang = language
            langStats[language, default: 0] += 1
            chunkIndex += 1
            onChunk(StreamChunk(index: chunkIndex, text: trimmed, language: language))
        }

        for await piece in samples {
            buffer.append(contentsOf: piece)
            // Emit every window we can now prove is not the last one.
            while consumedBase + buffer.count > absStart + windowSamples {
                let localStart = absStart - consumedBase
                let window = Array(buffer[localStart..<localStart + windowSamples])
                await process(window: window)
                absStart += step
                let drop = absStart - consumedBase
                if drop > 0 {
                    buffer.removeFirst(min(drop, buffer.count))
                    consumedBase += drop
                }
            }
        }

        // Stream closed: the single remaining window (if any) is the last one,
        // truncated to whatever samples are left.
        let totalCount = consumedBase + buffer.count
        if absStart < totalCount {
            let localStart = absStart - consumedBase
            let window = Array(buffer[localStart..<buffer.count])
            await process(window: window)
        }

        if texts.isEmpty, let lastEngineError {
            throw lastEngineError
        }
        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats)
    }
}
