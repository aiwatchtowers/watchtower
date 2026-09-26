import Foundation

/// Qwen3-private windowed decode loop: cuts the recording into WindowPlanner
/// windows (same silence-snapped boundaries the Whisper stack uses) and decodes
/// each window with the injected closure, so peak memory is bounded by one
/// window instead of the whole clip. Batch and live both run THIS loop — batch
/// wraps the full buffer in a single-yield stream — so their outputs are
/// identical by construction rather than by a pinned invariant.
///
/// Deliberately NOT the Whisper stack: WindowedTranscriber/StreamingTranscriber
/// are Whisper-internal (sticky language detection Qwen3 cannot feed). Qwen3
/// exposes no language detection, so segments are labeled with the forced
/// language or "auto", and langStats is populated only when a language is
/// forced.
///
/// Error semantics mirror StreamingTranscriber: a window whose decode throws is
/// skipped and remembered, the run throws only when every window failed, and a
/// cancelled run returns its partial output promptly.
struct Qwen3Windower {
    let config: TranscriptionConfig
    /// Synchronous whole-window decode (production: `Qwen3ASRModel.transcribe`,
    /// a blocking MLX call; tests: a fake). Called serially, never concurrently.
    let decode: ([Float]) throws -> String

    init(config: TranscriptionConfig, decode: @escaping ([Float]) throws -> String) {
        self.config = config
        self.decode = decode
    }

    /// `windowTotal` is the pre-planned window count batch passes through to
    /// `progress` (0 when unknown, i.e. live). `progress` fires after every
    /// window including silent/failed ones, mirroring WindowedTranscriber.
    func run(samples: AsyncStream<[Float]>,
             windowTotal: Int,
             progress: @escaping @Sendable (Int, Int) -> Void,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        let planner = WindowPlanner(config: config)
        let label = config.forcedLanguage ?? "auto"

        var buffer: [Float] = []      // buffer[0] is absolute sample `consumedBase`
        var consumedBase = 0
        var absStart = 0

        var texts: [String] = []
        var segments: [TranscriptSegment] = []
        var lastDecodeError: Error?
        var chunkIndex = 0
        var processed = 0

        func process(window: [Float], windowStart: Int) {
            processed += 1
            defer { progress(processed, windowTotal) }
            let text: String
            do {
                text = try decode(window)
            } catch {
                lastDecodeError = error
                return // skipped: not in text/segments, chunk indices stay contiguous
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return } // silent window
            let rate = Double(TranscriptionConfig.sampleRate)
            texts.append(trimmed)
            segments.append(TranscriptSegment(text: trimmed,
                                              startSec: Double(windowStart) / rate,
                                              endSec: Double(windowStart + window.count) / rate,
                                              language: label))
            chunkIndex += 1
            onChunk(StreamChunk(index: chunkIndex, text: trimmed, language: label))
        }

        // Decodes the window and drops consumed samples from the buffer.
        func emit(_ range: Range<Int>) {
            let window = Array(buffer[(range.lowerBound - consumedBase)..<(range.upperBound - consumedBase)])
            process(window: window, windowStart: range.lowerBound)
            absStart = planner.nextStart(after: range)
            let drop = absStart - consumedBase
            if drop > 0 {
                buffer.removeFirst(min(drop, buffer.count))
                consumedBase += drop
            }
        }

        for await piece in samples {
            if Task.isCancelled { break }
            buffer.append(contentsOf: piece)
            while let range = planner.nextRange(
                start: absStart,
                total: consumedBase + buffer.count,
                isFinal: false,
                sample: { buffer[$0 - consumedBase] }
            ) {
                if Task.isCancelled { break }
                emit(range)
            }
            if Task.isCancelled { break }
        }

        // Stream closed: the total is final; the remainder can still hold
        // several windows (snapped cuts land short of nominal ends).
        while !Task.isCancelled,
              let range = planner.nextRange(
                  start: absStart,
                  total: consumedBase + buffer.count,
                  isFinal: true,
                  sample: { buffer[$0 - consumedBase] }
              ) {
            let isLast = planner.isLastWindow(start: range.lowerBound, total: consumedBase + buffer.count)
            emit(range)
            if isLast { break }
        }

        if texts.isEmpty, let lastDecodeError {
            throw lastDecodeError
        }
        var langStats: [String: Int] = [:]
        if let forced = config.forcedLanguage, !texts.isEmpty {
            langStats[forced] = texts.count
        }
        return TranscriptionOutput(text: texts.joined(separator: "\n"),
                                   langStats: langStats,
                                   segments: segments)
    }
}
