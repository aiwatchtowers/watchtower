import Foundation

/// One timestamped segment of a transcribed window (seconds relative to the
/// window start). An empty array from the engine = no speech in the window.
struct TranscribedSegment: Equatable, Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
}

/// Abstraction over the on-device STT engine so tests never load WhisperKit/CoreML.
protocol TranscriptionEngine: Sendable {
    /// Language probabilities for one audio window (16 kHz mono Float32 samples).
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    /// Transcribe one window with the language forced.
    func transcribeWindow(_ samples: [Float], language: String) async throws -> [TranscribedSegment]
}

/// Windowed-transcription parameters. Defaults are ported verbatim from snoop:
/// 20 s windows with 1 s overlap, langset {ru, uk, en}, confidence threshold 0.6,
/// margin 0.2 over the runner-up, first-window fallback "ru".
struct TranscriptionConfig: Equatable {
    var windowSec: Double = 20
    var overlapSec: Double = 1.0
    /// Snap window boundaries to the quietest point within ±boundarySnapSec
    /// of the nominal end (0 disables snapping — exact legacy boundaries).
    var boundarySnapSec: Double = 2.5
    var langset: [String] = ["ru", "uk", "en"]
    var langThreshold: Float = 0.6
    var margin: Float = 0.2
    var firstWindowDefault: String = "ru"
    var forcedLanguage: String?   // non-nil disables detection entirely
    static let sampleRate = 16_000
}

/// One timestamped segment of the full recording (absolute seconds), carrying
/// the language of its parent window. Feeds the diarization post-pass.
struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
    let language: String
}

/// Result of transcribing a full recording.
struct TranscriptionOutput: Equatable {
    let text: String                 // newline-joined non-empty window texts
    let langStats: [String: Int]     // windows per language (speech windows only)
    var segments: [TranscriptSegment] = [] // absolute-timestamped, for diarization
}

extension TranscriptionConfig {
    /// Builds a config from the `transcription.*` UserDefaults keys backing the
    /// Settings "Transcription" section. Any key that is absent keeps the struct
    /// default, so an untouched install behaves exactly like `TranscriptionConfig()`.
    /// The model name is NOT read here — it is a separate key consumed by the
    /// engine factory. `defaults` is injectable so tests use an isolated suite.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> TranscriptionConfig {
        var config = TranscriptionConfig()

        if let raw = defaults.string(forKey: "transcription.langset") {
            let parsed = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !parsed.isEmpty { config.langset = parsed }
        }
        if defaults.object(forKey: "transcription.windowSec") != nil {
            let value = defaults.double(forKey: "transcription.windowSec")
            if value > 0 { config.windowSec = value }
        }
        if defaults.object(forKey: "transcription.boundarySnapSec") != nil {
            let value = defaults.double(forKey: "transcription.boundarySnapSec")
            if value >= 0 { config.boundarySnapSec = value }
        }
        if defaults.object(forKey: "transcription.langThreshold") != nil {
            config.langThreshold = Float(defaults.double(forKey: "transcription.langThreshold"))
        }
        if defaults.object(forKey: "transcription.margin") != nil {
            config.margin = Float(defaults.double(forKey: "transcription.margin"))
        }
        let force = (defaults.string(forKey: "transcription.forceLang") ?? "")
            .trimmingCharacters(in: .whitespaces)
        config.forcedLanguage = force.isEmpty ? nil : force

        return config
    }
}

/// Detection with sticky fallback, shared by WindowedTranscriber (batch) and
/// StreamingTranscriber (live) so their language selection cannot drift. A
/// detection error is treated as low confidence (fallback), never fatal.
/// Only called when `config.forcedLanguage == nil`.
func resolveWindowLanguage(
    for window: [Float],
    previous: String?,
    config: TranscriptionConfig,
    engine: TranscriptionEngine
) async -> String {
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
