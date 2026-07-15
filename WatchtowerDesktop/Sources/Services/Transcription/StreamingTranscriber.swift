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
/// Boundaries come from the shared `WindowPlanner`: a window at absolute
/// offset `start` is emitted as soon as the buffer covers its full snap zone
/// (`planner.decidableCount`) — the cut is then identical to what the batch
/// path derives on the full recording. After the stream closes the total is
/// final, so the remaining windows (snapped cuts can leave more than one) are
/// planned with `isFinal` until the truncated last window is emitted. Silent
/// and failed windows never stick and are not counted; total engine failure
/// throws rather than masquerading as all-silence.
///
/// Cooperatively cancellable: `Task.isCancelled` is checked at the top of the
/// outer sample loop and before every window transcription, so a caller that
/// cancels the driving `Task` (e.g. after a stop-time error) gets a prompt
/// return instead of grinding through the rest of a buffered backlog. A
/// cancelled run returns whatever partial output it already has rather than
/// throwing — the caller on that path discards the result anyway.
struct StreamingTranscriber {
    let engine: TranscriptionEngine
    let config: TranscriptionConfig

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        let planner = WindowPlanner(config: config)

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
            if Task.isCancelled { break }
            buffer.append(contentsOf: piece)
            // Emit every window whose cut is already decidable (its full snap
            // zone is buffered, proving it is not the last one).
            while let range = planner.nextRange(
                start: absStart,
                total: consumedBase + buffer.count,
                isFinal: false,
                sample: { buffer[$0 - consumedBase] }
            ) {
                if Task.isCancelled { break }
                let window = Array(buffer[(range.lowerBound - consumedBase)..<(range.upperBound - consumedBase)])
                await process(window: window)
                absStart = planner.nextStart(after: range)
                let drop = absStart - consumedBase
                if drop > 0 {
                    buffer.removeFirst(min(drop, buffer.count))
                    consumedBase += drop
                }
            }
            if Task.isCancelled { break }
        }

        // Stream closed: total is now final. The remainder can hold several
        // windows (snapped cuts land short of nominal ends), so keep planning
        // with isFinal until the truncated last window is emitted. Skipped
        // when cancelled, so a cancelled task never runs one more (possibly
        // heavy) window either.
        while !Task.isCancelled,
              let range = planner.nextRange(
                  start: absStart,
                  total: consumedBase + buffer.count,
                  isFinal: true,
                  sample: { buffer[$0 - consumedBase] }
              ) {
            let window = Array(buffer[(range.lowerBound - consumedBase)..<(range.upperBound - consumedBase)])
            await process(window: window)
            if planner.isLastWindow(start: range.lowerBound, total: consumedBase + buffer.count) { break }
            absStart = planner.nextStart(after: range)
            let drop = absStart - consumedBase
            if drop > 0 {
                buffer.removeFirst(min(drop, buffer.count))
                consumedBase += drop
            }
        }

        if texts.isEmpty, let lastEngineError {
            throw lastEngineError
        }
        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats)
    }
}
