import Foundation
import WatchtowerCore

/// What the gate found in one window.
enum WindowSpeech: Equatable {
    /// The gate is off (`speechGate` false, or no detector): decode as before.
    case ungated
    /// Too little speech to decode (`SpeechGate.minWindowSpeechSec`).
    case silent
    /// Speech ranges, sample offsets relative to the window.
    case speech([Range<Int>])
}

/// One recording's window gate (spec D2, board #554): L1 asks the detector
/// whether a window holds speech before anything is decoded, L2 drops the
/// decoded segments that lie outside it. Shared by `WindowedTranscriber`
/// (batch), `StreamingTranscriber` (live) and `Qwen3Windower` (L1 only), and
/// by `speechOnlyBuffer` for the whole-buffer engines, so the loops cannot
/// drift — the same rule as `liftWindowSegments`.
///
/// The first detector error moves the rest of the recording to
/// `EnergySpeechDetector` — never "no gate", so a broken model cannot quietly
/// restore the hallucinating path, and no per-window retry of a model that
/// failed to load. The gate lives for one transcribe/run call, so the next
/// recording tries the detector again. The switch is logged once and the
/// gate's counts once at the end, never text.
struct WindowSpeechGate {
    private let detector: SpeechDetector?
    private let fallback = EnergySpeechDetector()
    private var detectorFailed = false
    private var silentWindows = 0
    private var fallbackWindows = 0
    private var droppedSegments = 0
    private var droppedChars = 0

    init(detector: SpeechDetector?, config: TranscriptionConfig) {
        self.detector = config.speechGate ? detector : nil
    }

    mutating func check(_ window: [Float]) async -> WindowSpeech {
        guard let detector else { return .ungated }
        var ranges: [Range<Int>]?
        if !detectorFailed {
            do {
                ranges = try await detector.speechRanges(in: window)
            } catch {
                // A cancelled run is not a detector failure: the window is
                // not decoded and the caller's cancel check ends the run —
                // batch and the whole-buffer engines throw CancellationError,
                // the live loops return their partial output (discarded).
                if error is CancellationError || Task.isCancelled { return .silent }
                detectorFailed = true
                NSLog("SpeechGate: speech detector failed (%@) — energy fallback for this recording",
                      String(describing: type(of: error)))
            }
        }
        if ranges == nil { fallbackWindows += 1 }
        let found = ranges ?? fallback.speechRanges(in: window)
        guard !SpeechGate.isSilent(found, sampleRate: TranscriptionConfig.sampleRate) else {
            silentWindows += 1
            return .silent
        }
        return .speech(found)
    }

    /// L2: the decoded segments of a speech window that overlap its speech.
    mutating func keep(_ segments: [TranscribedSegment], in verdict: WindowSpeech) -> [TranscribedSegment] {
        guard case let .speech(ranges) = verdict else { return segments }
        let kept = segments.filter {
            SpeechGate.keepsSegment(startSec: $0.startSec, endSec: $0.endSec, speech: ranges,
                                    sampleRate: TranscriptionConfig.sampleRate)
        }
        droppedSegments += segments.count - kept.count
        droppedChars += segments.map(\.text.count).reduce(0, +) - kept.map(\.text.count).reduce(0, +)
        return kept
    }

    /// One line per recording, counts only — enough to tell "a defence ate
    /// it" from "the model never heard it" when a transcript looks thin.
    /// `engineDrops` adds what the engine dropped itself (L3, phrase filter).
    func logSummary(engineDrops: WindowDropCounts) {
        let total = silentWindows + fallbackWindows + droppedSegments + engineDrops.confidence + engineDrops.phrase
        guard total > 0 else { return }
        NSLog("SpeechGate: dropped vad=%d window(s), outside_speech=%d, confidence=%d, phrase=%d segment(s), "
              + "%d chars; %d window(s) on the energy fallback",
              silentWindows, droppedSegments, engineDrops.confidence, engineDrops.phrase,
              droppedChars + engineDrops.droppedChars, fallbackWindows)
    }
}

/// One window's outcome from `decodeGatedWindow`.
enum GatedWindowDecode {
    /// No speech by the gate: not detected, not decoded.
    case silent
    /// The engine threw: the window is skipped, as before the gate.
    case failed(Error)
    /// The decoded segments that survived L2, and the window's language.
    case decoded([TranscribedSegment], language: String)
}

/// The per-window step both loops share, in the spec D2 order: gate (L1) →
/// language → decode (L3 and the phrase filter inside the engine) → L2. The
/// callers keep their own bookkeeping (lift, language stickiness, prompt
/// state), which is identical between them.
func decodeGatedWindow(
    _ window: [Float],
    gate: inout WindowSpeechGate,
    previousLanguage: String?,
    promptText: String?,
    config: TranscriptionConfig,
    engine: WhisperWindowEngine
) async -> GatedWindowDecode {
    let verdict = await gate.check(window)
    if verdict == .silent { return .silent }
    let language: String
    if let forced = config.forcedLanguage {
        language = forced
    } else {
        language = await resolveWindowLanguage(for: window, previous: previousLanguage, config: config, engine: engine)
    }
    let prompt = contextPromptTail(prevText: promptText, prevLang: previousLanguage, language: language, config: config)
    do {
        let segments = try await engine.transcribeWindow(window, language: language, prompt: prompt,
                                                         dropDoubtful: config.speechGate)
        return .decoded(gate.keep(segments, in: verdict), language: language)
    } catch {
        return .failed(error)
    }
}

/// One speech detector per transcriber, created on the first call whose
/// config has `speechGate` on — the config only arrives there — and reused
/// for the transcriber's lifetime; a gate-off config (dictation) never
/// creates one.
final class SpeechDetectorSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: SpeechDetector?

    /// `detector` replaces the lazily created Silero one (tests).
    init(detector: SpeechDetector? = nil) { self.detector = detector }

    func detector(for config: TranscriptionConfig) -> SpeechDetector? {
        guard config.speechGate else { return nil }
        return lock.withLock {
            if let detector { return detector }
            let created = SileroSpeechDetector()
            detector = created
            return created
        }
    }
}

/// L5 (spec D5) for engines that decode the whole recording in one call
/// (Parakeet, Apple): the detector runs over the recording in 30 s chunks
/// with the window gate's rules (minimum speech, per-recording energy
/// fallback), and every sample outside the padded speech is set to 0.
/// Returns the samples to decode — unchanged when the gate is off, nil when
/// the recording holds no speech at all (nothing to decode) — and the gate,
/// whose counts the caller logs once the text is filtered.
func speechOnlyBuffer(
    _ samples: [Float],
    detector: SpeechDetector?,
    config: TranscriptionConfig
) async -> (samples: [Float]?, gate: WindowSpeechGate) {
    var gate = WindowSpeechGate(detector: detector, config: config)
    guard detector != nil, config.speechGate else { return (samples, gate) }
    let chunk = 30 * TranscriptionConfig.sampleRate
    var speech: [Range<Int>] = []
    for start in stride(from: 0, to: samples.count, by: chunk) {
        let end = min(start + chunk, samples.count)
        if case let .speech(ranges) = await gate.check(Array(samples[start..<end])) {
            speech += ranges.map { (start + $0.lowerBound)..<(start + $0.upperBound) }
        }
    }
    guard !speech.isEmpty else { return (nil, gate) }
    return (SpeechGate.muted(samples, keeping: speech), gate)
}

/// The phrase filter on a non-Whisper engine's text (Qwen3 window text,
/// Parakeet/Apple transcript), trimmed, with what it removed added to
/// `drops` for the gate's summary line. Part of the gate: with `speechGate`
/// off (the kill switch, dictation) the text is only trimmed, as before.
func withoutHallucinatedPhrases(
    _ text: String,
    config: TranscriptionConfig,
    counting drops: inout WindowDropCounts
) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard config.speechGate else { return trimmed }
    let cleaned = WhisperHallucinationFilter.clean(text)
    if cleaned != trimmed {
        drops.add(WindowDropCounts(phrase: 1, droppedChars: trimmed.count - cleaned.count))
    }
    return cleaned
}
