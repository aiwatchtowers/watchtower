import Foundation

/// L3 of the silence defence (board #554, spec D3): whether a decoded Whisper
/// segment is too unsure of itself to keep. Pure, so the rule is pinned
/// without WhisperKit. The first three thresholds are WhisperKit's own
/// decoding defaults, pinned in the engine's `DecodingOptions` so an upgrade
/// cannot move them; `minAvgLogprob` is ours.
///
/// `avgLogprob` is the mean log-probability of the segment's OWN text tokens:
/// WhisperKit's segment `avgLogprob` is the whole decode pass's, shared by
/// every segment of the pass, so a hallucinated "Спасибо." glued to real
/// speech inherits the speech's confidence. `noSpeechProb` is WhisperKit's;
/// 0.18 never computes it (hard-coded 0 in its TextDecoder), so the
/// no-speech rule is dormant until an upgrade fills it in.
package enum WhisperSegmentConfidence {
    package static let noSpeechThreshold: Float = 0.6
    package static let logProbThreshold: Float = -1.0
    package static let compressionRatioThreshold: Float = 2.4
    /// Below this average log-probability a segment goes whatever the
    /// no-speech head says. Tuned on the bench corpus (2026-10-12, Whisper
    /// large-v3-v20240930 over the 58 clips, speech gate on, ~125 segments
    /// per run): clean real speech scores −0.05…−0.53, but a real sentence
    /// under pink noise at 0 dB SNR, decoded on WhisperKit's temperature
    /// fallback, scored −1.48 — and the leftover insertions next to speech
    /// sit inside that range («Спасибо.» −1.33, «Звучить.» −1.05, «Играет
    /// музыка.» −0.63, "Thank you." −0.39…−0.59), so no cut-off separates
    /// them from real speech. −1.6 keeps every real sentence and drops only
    /// garbage: a lone "." (−2.60) and a garbled re-read (−2.05); −1.2 lost
    /// the −1.48 sentence.
    package static let minAvgLogprob: Float = -1.6

    package enum Reason: String, Sendable {
        /// The model heard no speech and was unsure of the text it wrote.
        case noSpeech
        /// The text repeats itself (a decoding loop).
        case repetition
        /// The model was very unsure of the text.
        case lowLogprob
    }

    /// nil = keep. A value exactly at a threshold keeps the segment.
    package static func dropReason(noSpeechProb: Float, avgLogprob: Float, compressionRatio: Float) -> Reason? {
        if noSpeechProb > noSpeechThreshold && avgLogprob < logProbThreshold { return .noSpeech }
        if compressionRatio > compressionRatioThreshold { return .repetition }
        if avgLogprob < minAvgLogprob { return .lowLogprob }
        return nil
    }

    package static func shouldDrop(noSpeechProb: Float, avgLogprob: Float, compressionRatio: Float) -> Bool {
        dropReason(noSpeechProb: noSpeechProb, avgLogprob: avgLogprob, compressionRatio: compressionRatio) != nil
    }
}
