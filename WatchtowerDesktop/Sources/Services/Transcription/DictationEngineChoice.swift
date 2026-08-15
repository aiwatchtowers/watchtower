import Foundation

/// The dictation-model picker's domain: which engine dictation runs on.
///
/// Deliberately decoupled from the meeting Engine/Model settings
/// (`transcription.provider`/`transcription.model`) — the meeting model is
/// picked for 30 s windows and full-quality recap, which is wrong for
/// dictation twice over (ten-second lumps, minute-plus cold load). Dictation
/// resolves only its own `dictation.model` key and never reads the meeting
/// keys, so changing one surface can never silently change the other.
enum DictationEngineChoice: Equatable {
    case apple
    case whisper(model: String)   // "large-v3-v20240930" | "small" | "base"

    /// Raw values stored under UserDefaults key "dictation.model".
    static let defaultsKey = "dictation.model"

    /// The only Whisper variants suitable for dictation's ~4 s windows.
    /// Full `large-v3` (load cost), `distil` (English-only), Parakeet
    /// (batch-only) and Qwen3 (heavy MLX) are excluded by design.
    static let whisperModels = ["large-v3-v20240930", "small", "base"]

    /// Absent/unknown key → .apple when appleSupported, else .whisper("small").
    /// Unknown values fall back to the default rather than erroring so a
    /// stale key from a newer/older build degrades to a working engine.
    /// "apple" stored but appleSupported false (OS downgrade / synced prefs)
    /// → .whisper("small"), the fastest sensible Whisper.
    static func resolve(rawValue: String?, appleSupported: Bool) -> Self {
        switch rawValue {
        case "apple" where appleSupported:
            return .apple
        case let raw? where whisperModels.contains(raw):
            return .whisper(model: raw)
        default:
            return appleSupported ? .apple : .whisper(model: "small")
        }
    }

    /// Convenience used by DictationCenter: reads the injected defaults and
    /// AppleDictationSession.isSupported (parameterized for tests).
    static func current(defaults: UserDefaults, appleSupported: Bool) -> Self {
        resolve(rawValue: defaults.string(forKey: defaultsKey), appleSupported: appleSupported)
    }

    /// Stable engine-slot key ("apple" / "whisper|<model>") — replaces the
    /// meeting-keys engineKey() in DictationCenter's warm logic, so a
    /// Settings change invalidates the warm slot only when the *dictation*
    /// choice actually moved.
    var engineKey: String {
        switch self {
        case .apple:
            return "apple"
        case .whisper(let model):
            return "whisper|\(model)"
        }
    }
}
