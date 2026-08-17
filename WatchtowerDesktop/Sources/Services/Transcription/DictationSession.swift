import Foundation

/// One dictation transcription session (realtime-dictation spec §2): consumes
/// the mic's 16 kHz sample stream, emits full-replacement display updates
/// while running — the FULL accumulated text so far, never a delta — and
/// returns the engine's final raw transcript when the stream ends
/// (single-pass: that return IS the raw text handed to cleanup).
protocol DictationTranscribing {
    func run(samples: AsyncStream<[Float]>,
             onUpdate: @escaping @MainActor (String) -> Void) async throws -> String
}

enum DictationSessionError: Error {
    /// The transcriber has no live session (batch-only provider). The center
    /// answers by batch-decoding its t0 buffer — the same fallback as a
    /// session that failed mid-stream.
    case liveUnsupported
}

/// Whisper pseudo-streaming lane: the existing provider live session over
/// short (~4 s) windows. Each finished speech window's text is appended to a
/// running accumulation, and every chunk fires `onUpdate` with the full
/// accumulated string (the center replaces its live text wholesale). The
/// returned string is the live output's final text as-is — the CENTER treats
/// an empty return as "batch-decode the buffer instead", exactly the
/// pre-seam semantics, so no emptiness policy lives here.
struct WhisperDictationSession: DictationTranscribing {
    let transcriber: Transcriber
    let config: TranscriptionConfig

    func run(samples: AsyncStream<[Float]>,
             onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let liveSession = transcriber.makeLiveSession(config: config) else {
            throw DictationSessionError.liveUnsupported
        }
        let accumulated = Accumulated()
        let output = try await liveSession.run(samples: samples) { chunk in
            Task { @MainActor in
                onUpdate(accumulated.append(chunk.text))
            }
        }
        return output.text
    }

    /// Chunk-text accumulation, main-actor-confined so updates compose in the
    /// per-chunk tasks' enqueue order — the pre-seam `liveText +=` shape,
    /// moved behind the seam.
    @MainActor
    private final class Accumulated {
        private var text = ""

        nonisolated init() {}

        func append(_ chunk: String) -> String {
            text += text.isEmpty ? chunk : " " + chunk
            return text
        }
    }
}
