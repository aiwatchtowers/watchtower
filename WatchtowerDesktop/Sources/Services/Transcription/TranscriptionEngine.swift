import Foundation

/// Abstraction over the on-device STT engine so tests never load WhisperKit/CoreML.
protocol TranscriptionEngine: Sendable {
    /// Language probabilities for one audio window (16 kHz mono Float32 samples).
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    /// Transcribe one window with the language forced. Returns raw text ("" = no speech).
    func transcribeWindow(_ samples: [Float], language: String) async throws -> String
}

/// Windowed-transcription parameters. Defaults are ported verbatim from snoop:
/// 20 s windows with 1 s overlap, langset {ru, uk, en}, confidence threshold 0.6,
/// margin 0.2 over the runner-up, first-window fallback "ru".
struct TranscriptionConfig: Equatable {
    var windowSec: Double = 20
    var overlapSec: Double = 1.0
    var langset: [String] = ["ru", "uk", "en"]
    var langThreshold: Float = 0.6
    var margin: Float = 0.2
    var firstWindowDefault: String = "ru"
    var forcedLanguage: String?   // non-nil disables detection entirely
    static let sampleRate = 16_000
}

/// Result of transcribing a full recording.
struct TranscriptionOutput: Equatable {
    let text: String                 // newline-joined non-empty window texts
    let langStats: [String: Int]     // windows per language (speech windows only)
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
