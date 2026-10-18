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
/// A window the detector cannot decide goes to `EnergySpeechDetector` —
/// never "no gate", so a broken model cannot quietly restore the
/// hallucinating path. The detector's model may still be loading (board
/// #564): the run waits for it once, at most `modelWait` (live 5 s, batch
/// 120 s), and after that asks without waiting, so a slow download costs a
/// run one bounded wait, not one per window; the window the model arrives
/// in is back on the model. A model that failed to load is asked the same
/// way (its loader retries at most once a minute). Any other detector error
/// moves the rest of the run to the energy fallback. The gate lives for one
/// transcribe/run call, so the next recording asks the detector afresh.
/// Each switch is logged once and the gate's counts once at the end, never
/// text.
struct WindowSpeechGate {
    /// The one wait a live run pays for a model still loading: the first
    /// window's decode is late by at most this.
    static let liveModelWait: Duration = .seconds(5)
    /// The one wait a batch run pays: long enough for a model download on
    /// most connections, where nobody watches a live panel.
    static let batchModelWait: Duration = .seconds(120)

    private let detector: SpeechDetector?
    private let fallback = EnergySpeechDetector()
    /// How long the next detector call waits for its model: the run's one
    /// wait until the model is first missed, `.zero` after.
    private var modelWait: Duration
    private var detectorFailed = false
    private var loadFailed = false
    private var missedModel = false
    private var notReadyLogged = false
    private var loadFailureLogged = false
    private var silentWindows = 0
    private var loadingWindows = 0
    private var failedWindows = 0
    private var droppedSegments = 0
    private var droppedChars = 0
    /// What the engine dropped itself in this run's decodes (L3, phrase filter).
    private var engineDrops = WindowDropCounts()

    init(detector: SpeechDetector?, config: TranscriptionConfig, modelWait: Duration) {
        self.detector = config.speechGate ? detector : nil
        self.modelWait = modelWait
    }

    mutating func check(_ window: [Float]) async -> WindowSpeech {
        guard let detector else { return .ungated }
        var ranges: [Range<Int>]?
        if detectorFailed {
            failedWindows += 1
        } else {
            do {
                ranges = try await detector.speechRanges(in: window, modelWait: modelWait)
                if missedModel {
                    missedModel = false
                    NSLog("SpeechGate: speech detector model loaded — back on the model after %d window(s) "
                          + "on the energy fallback", loadingWindows + failedWindows)
                }
            } catch {
                // A cancelled run is not a detector failure: the window is
                // not decoded and the caller's cancel check ends the run —
                // batch and the whole-buffer engines throw CancellationError,
                // the live loops return their partial output (discarded).
                // Only the caller's own cancel counts: a model load's errors
                // come wrapped (`SpeechDetectorLoadFailed`).
                if Task.isCancelled { return .silent }
                missed(error)
            }
        }
        let found = ranges ?? fallback.speechRanges(in: window)
        guard !SpeechGate.isSilent(found, sampleRate: TranscriptionConfig.sampleRate) else {
            silentWindows += 1
            return .silent
        }
        return .speech(found)
    }

    /// Books a window the detector could not decide (the energy fallback
    /// decides it) and logs the first of each kind.
    private mutating func missed(_ error: Error) {
        modelWait = .zero
        missedModel = true
        switch error {
        case is SpeechDetectorNotReady where !loadFailed:
            loadingWindows += 1
            if !notReadyLogged {
                notReadyLogged = true
                NSLog("SpeechGate: speech detector model not loaded yet — energy fallback until it is")
            }
        case is SpeechDetectorNotReady:
            failedWindows += 1
        case let failure as SpeechDetectorLoadFailed:
            loadFailed = true
            failedWindows += 1
            if !loadFailureLogged {
                loadFailureLogged = true
                NSLog("SpeechGate: speech detector model failed to load (%@) — energy fallback, the model is "
                      + "retried at most once a minute", String(describing: type(of: failure.underlying)))
            }
        default:
            detectorFailed = true
            missedModel = false
            failedWindows += 1
            NSLog("SpeechGate: speech detector failed (%@) — energy fallback for this recording",
                  String(describing: type(of: error)))
        }
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

    /// Adds one decode's engine drops (`decodeGatedWindow`).
    mutating func countEngineDrops(_ drops: WindowDropCounts) {
        engineDrops.add(drops)
    }

    /// One line per recording, counts only — enough to tell "a defence ate
    /// it" from "the model never heard it" when a transcript looks thin.
    /// `callerDrops` adds what the caller dropped itself (the phrase filter
    /// on a non-Whisper engine's text) to the engine drops counted here.
    func logSummary(callerDrops: WindowDropCounts = WindowDropCounts()) {
        if let line = summary(callerDrops: callerDrops) { NSLog("%@", line) }
    }

    /// `logSummary`'s line; nil when nothing was dropped.
    func summary(callerDrops: WindowDropCounts = WindowDropCounts()) -> String? {
        var drops = engineDrops
        drops.add(callerDrops)
        let total = silentWindows + loadingWindows + failedWindows + droppedSegments + drops.confidence
            + drops.phrase
        guard total > 0 else { return nil }
        return String(format: "SpeechGate: dropped vad=%d window(s), outside_speech=%d, confidence=%d, phrase=%d "
                      + "segment(s), %d chars; energy fallback for %d window(s) while the model loaded, "
                      + "%d after a detector failure",
                      silentWindows, droppedSegments, drops.confidence, drops.phrase,
                      droppedChars + drops.droppedChars, loadingWindows, failedWindows)
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
        let decoded = try await engine.transcribeWindow(window, language: language, prompt: prompt,
                                                        dropDoubtful: config.speechGate)
        gate.countEngineDrops(decoded.drops)
        return .decoded(gate.keep(decoded.segments, in: verdict), language: language)
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

/// What a whole-buffer engine decodes after L5: the recording and the
/// padded speech to keep (nil = all of it). The muting is left to the
/// engine (board #564), so one that copies the samples into its own buffer
/// anyway (Apple's PCM buffer) mutes them on the way instead of holding one
/// more copy of the recording — 460 MB for 2 h at 16 kHz.
struct SpeechOnlyAudio {
    let samples: [Float]
    let speech: [Range<Int>]?

    /// The samples with everything outside the speech set to exactly 0:
    /// one new buffer when anything is muted, the samples themselves when
    /// nothing is.
    func muted() -> [Float] {
        speech.map { SpeechGate.muted(samples, keeping: $0) } ?? samples
    }

    /// `muted()` written into `destination` (at least `samples.count` long).
    func writeMuted(into destination: UnsafeMutableBufferPointer<Float>) {
        if let speech {
            SpeechGate.writeMuted(samples, keeping: speech, into: destination)
        } else {
            _ = destination.initialize(fromContentsOf: samples)
        }
    }
}

/// How far `speechOnlyBuffer`'s chunks overlap: well above the longest
/// speech a seam can hide (a run under the 0.3 s minimum on both sides of
/// it), so any run cut by a seam lies whole inside the next chunk or keeps a
/// piece longer than the overlap in the previous one.
let wholeBufferChunkOverlapSec = 2.0

/// L5 (spec D5) for engines that decode the whole recording in one call
/// (Parakeet, Apple): the detector runs over the recording in 30 s chunks
/// with the window gate's rules (minimum speech, the batch model wait, the
/// energy fallback), and every sample outside the padded speech is to be set
/// to 0 (`SpeechOnlyAudio`). Neighbouring chunks overlap by
/// `wholeBufferChunkOverlapSec` and their speech is joined, so a word cut by
/// a chunk seam — two pieces each under the detector's minimum speech — is
/// still found whole in the next chunk (board #564); the gate's summary
/// counts chunks, so its `vad=` figure here counts overlapping chunks, not
/// unique audio. Returns the audio to decode — nothing to mute when the gate
/// is off or the speech covers the whole recording, nil when the recording
/// holds no speech at all (nothing to decode) — and the gate, whose counts
/// the caller logs once the text is filtered.
func speechOnlyBuffer(
    _ samples: [Float],
    detector: SpeechDetector?,
    config: TranscriptionConfig
) async -> (audio: SpeechOnlyAudio?, gate: WindowSpeechGate) {
    var gate = WindowSpeechGate(detector: detector, config: config, modelWait: WindowSpeechGate.batchModelWait)
    guard detector != nil, config.speechGate else { return (SpeechOnlyAudio(samples: samples, speech: nil), gate) }
    let chunk = 30 * TranscriptionConfig.sampleRate
    let overlap = Int(wholeBufferChunkOverlapSec * Double(TranscriptionConfig.sampleRate))
    var speech: [Range<Int>] = []
    for start in stride(from: 0, to: samples.count, by: chunk - overlap) {
        if Task.isCancelled { break } // the caller's cancel check ends the run
        let end = min(start + chunk, samples.count)
        if case let .speech(ranges) = await gate.check(Array(samples[start..<end])) {
            speech += ranges.map { (start + $0.lowerBound)..<(start + $0.upperBound) }
        }
        if end == samples.count { break }
    }
    speech = SpeechGate.merged(speech)
    guard !speech.isEmpty else { return (nil, gate) }
    let everything = speech == [0..<samples.count]
    return (SpeechOnlyAudio(samples: samples, speech: everything ? nil : speech), gate)
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
