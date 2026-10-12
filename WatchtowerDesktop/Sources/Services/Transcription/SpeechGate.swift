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
/// (batch) and `StreamingTranscriber` (live) — and later the Qwen3 windower —
/// so the loops cannot drift, the same rule as `liftWindowSegments`.
///
/// A detector error on a window falls back to `EnergySpeechDetector` for that
/// window — never "no gate", so a broken model cannot quietly restore the
/// hallucinating path. The fallback is logged once per recording and the
/// gate's counts once at the end, never text.
struct WindowSpeechGate {
    private let detector: SpeechDetector?
    private let fallback = EnergySpeechDetector()
    private var silentWindows = 0
    private var fallbackWindows = 0
    private var droppedSegments = 0
    private var droppedChars = 0

    init(detector: SpeechDetector?, config: TranscriptionConfig) {
        self.detector = config.speechGate ? detector : nil
    }

    mutating func check(_ window: [Float]) async -> WindowSpeech {
        guard let detector else { return .ungated }
        let ranges: [Range<Int>]
        do {
            ranges = try await detector.speechRanges(in: window)
        } catch {
            if fallbackWindows == 0 {
                NSLog("SpeechGate: speech detector failed (%@) — energy fallback for this recording",
                      String(describing: type(of: error)))
            }
            fallbackWindows += 1
            ranges = fallback.speechRanges(in: window)
        }
        guard !SpeechGate.isSilent(ranges, sampleRate: TranscriptionConfig.sampleRate) else {
            silentWindows += 1
            return .silent
        }
        return .speech(ranges)
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

    /// Counts only — enough to tell "the gate ate it" from "the model never
    /// heard it" when a transcript looks thin.
    func logSummary() {
        guard detector != nil, silentWindows + fallbackWindows + droppedSegments > 0 else { return }
        NSLog("SpeechGate: %d silent window(s) skipped, %d segment(s) / %d chars outside speech dropped, "
              + "%d window(s) on the energy fallback",
              silentWindows, droppedSegments, droppedChars, fallbackWindows)
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
        let segments = try await engine.transcribeWindow(window, language: language, prompt: prompt)
        return .decoded(gate.keep(segments, in: verdict), language: language)
    } catch {
        return .failed(error)
    }
}
